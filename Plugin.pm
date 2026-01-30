=head Infos
Sven 2026-01-29 enhancements based on version 1.400 up to 3.6.7

This program is free software; you can redistribute it and/or label
modify it under the terms of the GNU General Public License, version 2.

 1. included a new album information menu befor playing the album
	It shows: Samplesize, Samplerate, Genre, Duration, Description if present, Goodies (Booklet) if present,
	trackcount, Credits including performers, Conductor if present, Artist, Composer, ReleaseDate, Label (with label albums),
	Copyright, add Album or Artist to your Qobuz favorites
 Enhanced Artist menu with biography, album list, title list, playlists, similar artists 
 2. added samplerate of currently streamed file in the 'More Info' menu
 3. added samplesize of currently streamed file in the 'More Info' menu
 4. shows conductor including artist information for classic albums
 5. added seeking inside flac files while playing
 6. added new preference 'FLAC 24 bits / 96 kHz (Hi-Res)'
 7. my prefered menu order in main menu
 8 added a menu for a playlist item with the playlist, duration, title count, description,
          owner (if present), genres, release date, update date, similar playlists (if present)
 9. added subscribe/unsubscribe of playlist subscribtion
10. added delete my own playlists
11. added much more compatibility and useability with LMS favorites
12. added a TrackMenu, you get it if you click on a track item and select the more... menu item, 2025-03-22
13. added genre filter for user favorites, albums and playlists 2025-09-17, the previous genre menu is removed
14. added albums of the week 2025-10-15 
15. added Radio feature based on an album, artist or a track 2025-10-23 
16. added Album suggestions based on an album 2025-10-25
17. removed QobuzMyWeeklyQ(), No longer supported by Qobuz 25-11-02 (30.6.4)
18. Completing the translations for Spanish.
19. added new artist page, labels, awards.
20. added new album list 'Release Radar' and 'Albums of the week'.
21. added list of labels to explore
22. added a list of all awards.
23. added new awards page and labels page, awards and labels page are used now in the album page
24. added new setting album view
25. added new enhanced search - a complete redesign using the new design element 'header' supported in material. 2025-12-28
26. Consideration of has_more in releases on the artist page 2025-12-28
27. added new search to global search 2025-12-29
28. Support for User_Id sent by the controller. Currently, this feature is only supported by my own extended version of Material.
29. New artist page - a complete redesign using the new design element 'header' supported in material.
30. New label  page - a complete redesign using the new design element 'header' supported in material.
31. New award  page - a complete redesign using the new design element 'header' supported in material.

all changes are marked with "#Sven" in source code
changed files: Common.pm, API.pm, Plugin.pm, ProtocolHandler.pm, Settings.pm, strings.txt and basic.html from .../Qobuz/HTML/EN/plugins/Qobuz/settings/basic.html

With the value type => 'link' a list with symbols gets the option "Toggle View"
With the value type => 'playlist' a list with symbols gets the option "Toggle View" and the "ADD" and "PLAY" buttons are displayed.
It should therefore only be used for track lists (album, tracks and playlists).
Since version 3.0.7 my hack of "My weekly Q" ist included in Qobuz plugin of Pierre Beck / Michael Herger
=cut

# $log->error(Data::Dump::dump( ));

package Plugins::Qobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Tie::RegexpHash;
use POSIX qw(strftime); #??? geht scheinbar auch ohne

use Slim::Formats::RemoteMetadata;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);
use Scalar::Util qw(looks_like_number);

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::ProtocolHandler;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);
use constant CLICOMMAND => 'qobuzquery';
use constant MAX_RECENT => 30;

use constant ALBUM => '1';
use constant EP => '2';
use constant SINGLE => '3';

# Keep in sync with Music & Artist Information plugin
my $WEBLINK_SUPPORTED_UA_RE = qr/\b(?:iPeng|SqueezePad|OrangeSqueeze|OpenSqueeze|Squeezer|Squeeze-Control)\b/i;
my $WEBBROWSER_UA_RE = qr/\b(?:FireFox|Chrome|Safari)\b/i;

my $GOODIE_URL_PARSER_RE = qr/\.(?:pdf|png|gif|jpg)$/i;

my $prefs = preferences('plugin.qobuz');

tie my %localizationTable, 'Tie::RegexpHash';

%localizationTable = (
	qr/^Livret Num.rique/i => 'PLUGIN_QOBUZ_BOOKLET'
);

$prefs->init({
	accounts => {},
	preferredFormat => 6,
	filterSearchResults => 0,
	playSamples => 1,
	dontImportPurchases => 1,
	classicalGenres => '',
	useClassicalEnhancements => 1,
	parentalWarning => 0,
	showDiscs => 0,
	groupReleases => 1,
	importWorks => 1,
	sortPlaylists => 1,
	showUserPurchases => 1,
	genreFilter => '##',
	genreFavsFilter => '##',
	sortArtistsAlpha => 1,
	albumViewType => 0,
});

$prefs->migrate(1,
	sub {
		my $token = $prefs->get('token');
		my $userdata = $prefs->get('userdata');

		# migrate existing account to new list of accounts
		if ($token && $userdata && (my $id = $userdata->{id})) {
			my $accounts = $prefs->get('accounts') || {};
			$accounts->{$id} = {
				token => $token,
				userdata => $userdata,
			};
		}

		$prefs->remove('token', 'userdata', 'userinfo', 'username');
		
		1;
	}
);

# reset the API ref when a player changes user
$prefs->setChange( sub {
	my ($pref, $userId, $client) = @_;
	$client->pluginData(api => 0);
}, 'userId');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.qobuz',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_QOBUZ',
	logGroups    => 'SCANNER',
} );

use constant PLUGIN_TAG => 'qobuz';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $cache = Plugins::Qobuz::API::Common->getCache();

#Sven 2022-05-10
sub initPlugin {
	my $class = shift;

	if (main::WEBUI) {
		require Plugins::Qobuz::Settings;
		Plugins::Qobuz::Settings->new();
	}

	Plugins::Qobuz::API->init(
		$class->_pluginDataFor('aid')
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		qobuz => 'Plugins::Qobuz::ProtocolHandler'
	);

	Slim::Formats::Playlists->registerParser('qbz', 'Plugins::Qobuz::PlaylistParser');

	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr|\.qobuz\.com/|,
		sub { $class->_pluginDataFor('icon') }
	);

	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( qobuz => ( # qobuzTrackInfo => (
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( qobuz => ( # qobuzArtistInfo => (
		func  => \&artistInfoMenu
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( qobuz => ( # qobuzAlbumInfo => (
		func  => \&albumInfoMenu
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( qobuz => ( # qobuzSearch => (
		after => 'top',
		func  => sub { #Sven 2025-12-29 
			my ( $client, $tags ) = @_;

			my $menuItems;

			QobuzSearch($client, sub{ my $result = shift; $menuItems =  $result->{items}; }, $tags);

			return {
					name  => cstring($client, getDisplayName()),
					image => 'html/images/search.png',
					items => $menuItems,
#					items => [{
#						name  => cstring($client, 'PLUGIN_QOBUZ_SEARCH', '', $tags->{search}),
#						image => 'html/images/search.png',
#						url   => \&QobuzSearch,
#						passthrough => [{ q => $tags->{search} }],
#					}],
			};
		},
	) );

	#Sven 2022-05-10 
	Slim::Menu::PlaylistInfo->registerInfoProvider( qobuz => ( # qobuzPlaylistInfo => (
		#after => 'playitem',
		func => \&albumInfoMenu
	) );

	#                                                          |requires Client
	#                                                          |  |is a Query
	#                                                          |  |  |has Tags
	#                                                          |  |  |  |Function to call
	#                                                          C  Q  T  F
	Slim::Control::Request::addDispatch(['qobuz', 'goodies'], [1, 1, 1, \&_getGoodiesCLI]);

	Slim::Control::Request::addDispatch(['qobuz', 'playalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	Slim::Control::Request::addDispatch(['qobuz', 'addalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	Slim::Control::Request::addDispatch(['qobuz','recentsearches'],[1, 0, 1, \&_recentSearchesCLI]);
	Slim::Control::Request::addDispatch(['qobuz', 'command', '_aParams'], [1, 0, 0, \&cliQobuzCommand]);

	# "Local Artwork" requires LMS 7.8+, as it's using its imageproxy.
	if (CAN_IMAGEPROXY) {
		require Slim::Web::ImageProxy;
		Slim::Web::ImageProxy->registerHandler(
			match => qr/static\.qobuz\.com/,
			func  => \&_imgProxy,
		);
	}

	if (CAN_IMPORTER) {
		# tell LMS that we need to run the external scanner
		Slim::Music::Import->addImporter('Plugins::Qobuz::Importer', { use => 1 });
	}

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
}

#Sven
sub postinitPlugin {
	my $class = shift;

	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Plugins::Qobuz::LastMix;
			Plugins::LastMix::Services->registerHandler('Plugins::Qobuz::LastMix', 'lossless');
		}
	}

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('qobuz', '/plugins/Qobuz/html/images/icon.png');

		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( qobuz => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'Qobuz'),
				type => 'link',
				icon => $class->_pluginDataFor('icon'),
				url  => \&browseArtistMenu,
			};
		} );

		main::INFOLOG && $log->is_info && $log->info("Successfully registered BrowseArtist handler for Qobuz");
	}
	
}

sub onlineLibraryNeedsUpdate {
	if (CAN_IMPORTER) {
		my $class = shift;
		require Plugins::Qobuz::Importer;
		return Plugins::Qobuz::Importer->needsUpdate(@_);
	}
	else {
		$log->warn('The library importer feature requires at least Logitech Media Server 8');
	}
}

sub getLibraryStats { if (CAN_IMPORTER) {
	require Plugins::Qobuz::Importer;
	my $totals = Plugins::Qobuz::Importer->getLibraryStats();
	return wantarray ? ('PLUGIN_QOBUZ', $totals) : $totals;
} }

sub getDisplayName { 'PLUGIN_QOBUZ' }

# don't add this plugin to the Extras menu
sub playerMenu {}

#Sven 2024-01-24 
sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $accountStatus = Plugins::Qobuz::API::Common::getAccountStatus($client, $args->{params}); #Sven 2026-01-13

	# $log->error(Data::Dump::dump($accountStatus));

	unless ( $accountStatus->{count} ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_QOBUZ_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

	my $items = [{
		name  => cstring($client, 'SEARCH'),
		image => 'html/images/search.png',
		type => 'link',
		url  => sub {
			my ($client, $cb, $params) = @_;
			my $items = [];

			my $i = 0;
			for my $recent ( @{ $prefs->get('qobuz_recent_search') || [] } ) {
				unshift @$items, {
					name  => $recent,
					type  => 'link',
					url => sub {
						my ($client, $cb, $params) = @_;
						QobuzSearch($client, $cb, { search => $recent });
					},
					itemActions => {
						info => {
							command     => ['qobuz', 'recentsearches'],
							fixedParams => { deleteMenu => $i++ },
						},
					},
					#passthrough => [ { type => 'search' } ],
				};
			}

			unshift @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_NEW_SEARCH'),
				type => 'search',
				#timeout => 35,
				url  => sub {
					my ($client, $cb, $params) = @_;
					addRecentSearch($params->{search});
					QobuzSearch($client, $cb, { search => $params->{search} });
				},
				#passthrough => [ { type => 'search' } ],
			};

			$cb->({ items => $items });
		},
	},{
#Sven - ab hier angepasst
		name  => cstring($client, 'PLUGIN_QOBUZ_USER_FAVORITES'),
		image => 'html/images/favorites.png',
		type  => 'menu', #Sven - view type
		items => [{
			name  => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECT'),
			image => 'html/images/genres.png',
			type  => 'menu', #Sven - view type
			url  => \&QobuzGenreSelection,
			passthrough => [{ filter => 'genreFavsFilter' }],
			}, {
			name  => cstring($client, 'ALBUMS'),
			image => 'html/images/albums.png',
			url   => \&QobuzUserFavorites,
			type  => 'albums', #Sven - view type
			passthrough => ['albums'],
			}, {
			name  => cstring($client, 'SONGS'),
			image => 'html/images/playlists.png',
			type  => 'playlist',
			url   => \&QobuzUserFavorites,
			passthrough => ['tracks'],
			}, {
			name  => cstring($client, 'ARTISTS'),
			image => 'html/images/artists.png',
			type  => 'artists', #Sven - view type
			url   => \&QobuzUserFavorites,
			passthrough => ['artists'],
			}
		],
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_ALBUM_PICKS'),
		image => 'html/images/albums.png',
		type  => 'menu', #Sven - view type
		url  => \&QobuzAlbums,
		passthrough => [{ genreId => '' }]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_LABELS'),
		image => 'html/images/albums.png',
		type  => 'menu', #Sven - view type
		url  => \&QobuzLabels,
		passthrough => [{ genreId => '' }]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_AWARDS'),
		image => 'html/images/albums.png',
		type  => 'menu', #Sven - view type
		url  => \&QobuzAwardsExplore,
		passthrough => [{ genreId => '' }]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS'),
		url  => \&QobuzPlaylistTags,
		type  => 'menu', #Sven - view type
		image => 'html/images/playlists.png',
		passthrough => [{ }]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_USERPLAYLISTS'),
		type  => 'playlists', #Sven - view type
		url  => \&QobuzUserPlaylists,
		image => 'html/images/playlists.png'
	}];
	
	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_USERPURCHASES'),
		type  => 'link',
		url  => \&QobuzUserPurchases,
		image => 'html/images/albums.png'
	} if ($prefs->get('showUserPurchases'));
	
	if ( $accountStatus->{accountSelect} ) {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&QobuzSelectAccount,
		};
	}
	
	$cb->({
		items => $items
	});
}

sub QobuzSelectAccount {
	my $cb = $_[1];

	my $account = Plugins::Qobuz::API::Common->getAccountData($_[0]);
	my $name    = $account->{userdata}->{display_name};

	my $items = [ map {
		{
			name => ($_->[0] eq $name) ? '(' . $name . ')' : $_->[0],
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				#$client->pluginData(api => 0);
				$prefs->client($client)->set('userId', $args->{id});

				$cb2->({ items => [{
					nextWindow => 'grandparent',
				}] });
			},
			passthrough => [{
				id => $_->[1]
			}],
			nextWindow => 'parent'
		}
	} @{ Plugins::Qobuz::API::Common->getAccountList() } ];

	$cb->({ items => $items });
}

#Sven 2025-11-06
sub QobuzValidateWebToken {
	my ($client, $cb, $params) = @_;

	return 0 unless (Plugins::Qobuz::API::Common->getToken($client) && ! Plugins::Qobuz::API::Common->getWebToken($client));
	
	my $username = Plugins::Qobuz::API::Common->username($client);

	$cb->({ items => [
		{
			type => 'textarea',
			name => cstring($client, 'PLUGIN_QOBUZ_REAUTH_DESC'),
		},{
			name  => sprintf('%s (%s)', cstring($client, 'PLUGIN_QOBUZ_PREFS_PASSWORD'), $username),
			type  => 'search',
			url  => sub {
				my ($client, $cb, $params) = @_;

				getAPIHandler($client)->login($username, $params->{search}, sub {
					my $success = shift;

					$cb->({ items => [ $success
						? {
							name => cstring($client, 'SETUP_CHANGES_SAVED'),
							nextWindow => 'home',
						}
						: {
							name => cstring($client, 'PLUGIN_QOBUZ_AUTH_FAILED'),
							nextWindow => 'parent',
						}
					] });
				},{
					cid => 1,
					token => 'success',
				});
			},
			passthrough => [ { type => 'search' } ],
		}
	] });

	return 1;
}

#Sven 2025-11-05 - get artists or playlists
# $args - contains a hash with the parameters for control
# cmd   - the command that is sent to the Qobuz server contains
# args  - Contains, if necessary, the parameters that must be sent with the command.
# type  - contains the name of the result hash, 'artists' or 'playlists'
sub QobuzGetList {
	my ($client, $cb, $params, $args) = @_;

	return if QobuzValidateWebToken(@_);

	my $type = $args->{type};

	getAPIHandler($client)->getData(sub {
		my $data = shift;
		
		my $items = [];

		if ($type eq 'artists') { $items = [map { _artistItem($client, $_, 1) } @{$data->{artists}->{items}}]; }
		elsif ($type eq 'playlists') { $items = [map { _playlistItem($_, 1) } @{$data->{playlists}->{items}}]; } 
		
		$cb->({ items => $items });
		
	}, $args);

}

#Sven 2025-10-24 - get albums from new API commands, the get command must to be in $args->{cmd}
# $args - contains a hash with the parameters for control
# cmd   - the command that is sent to the Qobuz server contains
# args  - Contains, if necessary, the parameters that must be sent with the command.
sub QobuzGetAlbums {
	my ($client, $cb, $params, $args) = @_;
	
	return if QobuzValidateWebToken(@_);
	
	unless (exists $args->{args}->{genre_ids}) { #Sven 2025-09-16 v30.6.2
		$args->{args}->{genre_ids} = _getGenres(); 
	}
	else {
		delete $args->{args}->{genre_ids} unless $args->{args}->{genre_ids};
	} 

	$args->{type} = 'albums';
	
	getAPIHandler($client)->getData(sub {
		my $albums = shift;

		my @items = map { 
			my $album = _albumItem($client, $_);
			$album->{line1} = Slim::Utils::DateTime::shortDateF($_->{released_at}) . ' - ' . $album->{line1} if ($args->{showDate});
			$album;
		} @{$albums->{albums}->{items}};

		if (scalar @items) {
			$cb->({ items => \@items });
		}
		else {
			$cb->({ items => [{	name => cstring($client, 'PLUGIN_QOBUZ_ALBUMLIST_EMPTY') }]}); #Sven 2025-12-14
		}
		
	}, $args);
}

#Sven 2025-10-23 - a radio tracklist compiled by Qobuz based on an album, an artist, or a track
sub QobuzRadio {
	my ($client, $cb, $params, $args) = @_;

	return if QobuzValidateWebToken(@_);
	
	getAPIHandler($client)->getRadio(sub {
		my $radio = shift;

		unless ($radio) {
			$log->error("Get Radio failed");
			$cb->();
			return;
		}

		my @tracks = map { _trackItem($client, $_, 1) } @{$radio->{tracks}->{items} || []};

		$cb->({ items => [
			{
				name  => cstring($client, 'PLUGIN_QOBUZ_RADIO_' . uc substr($radio->{type}, 6)) . ' - ' . $radio->{title},
				image => $radio->{images}->{large},
				type  => 'playlist',
				items => \@tracks,
			}, {
				name => _countDuration($client, $radio->{track_count}, $radio->{duration}),
				type => 'text',
			}
		]});
	}, $args);
}

#Sven 2025-11-05 - a selection of labels suggested by qobuz
sub QobuzLabels {
	my ($client, $cb, $params, $args) = @_;

	return if QobuzValidateWebToken(@_);

	$args->{cmd}  = 'label/explore'; 
	$args->{args} = { limit => 95 };

	getAPIHandler($client)->getData(sub {
		my $labels = shift;

		my @items = map { {
				name  => $_->{name},
				image => $_->{image}, 
				type  => 'link',
				url   => \&QobuzLabelPage,
				passthrough => [ $_->{id} ],
			} } @{$labels->{items} || []};
		
		$cb->({ items => \@items });
	}, $args);
}

#Sven 2025-11-05 - the label info page
sub QobuzLabelPage {
	my ($client, $cb, $params, $labelId) = @_;

	return if QobuzValidateWebToken(@_);

	my $args = { cmd => 'label/page', args => { label_id => $labelId } };

	getAPIHandler($client)->getData(sub {
		my $label = shift;

		my $items = [];

		if ($label->{top_artists}) {
			my @artists = map { _artistItem($client, $_, 1) } @{$label->{top_artists}->{items}};
			if (scalar @artists) {
				my $name = cstring($client, 'PLUGIN_QOBUZ_TOP_ARTISTS');
				my $item = {
					image => 'html/images/artists.png',
					type  => 'header',
				};
				if ($label->{top_artists}->{has_more}) {
					$name .= "	(" . cstring($client, 'PLUGIN_QOBUZ_ALL') . ")";
					$item->{url} = \&QobuzGetList;
					$item->{passthrough} = [{ type => 'artists', cmd => 'label/getTopArtists', args => { label_id => $labelId } }];
				}
				$item->{name} = $name;
				push @$items, $item;
				push @$items, @artists;
			}	
		}

		if ($label->{releases}) {
			for my $releases (@{$label->{releases}}) {		
				my @albums = map { _albumItem($client, $_) } @{$releases->{data}->{items}};
				my $name   = cstring($client, 'PLUGIN_QOBUZ_LAB_'. uc($releases->{id}));
				if (scalar @albums) {
					my $item = {
						image => 'html/images/albums.png',
						type  => 'header',
					};
					if ($releases->{data}->{has_more}) {
						$name .= "	(" . cstring($client, 'PLUGIN_QOBUZ_ALL') . ")";
						my $cmd;
						if ($releases->{id} eq 'all' ) { $cmd = 'label/getAlbums'; }
						elsif ($releases->{id} eq 'awardedReleases' ) { $cmd = 'label/getAwardedReleases'; }
						if ($cmd) {
							$item->{url} = \&QobuzGetAlbums;
							$item->{passthrough} = [{ cmd => $cmd, args => { label_id => $labelId, sort => 'release_date', order => 'desc' } }];
						}
					}
					$item->{name} = $name;
					push @$items, $item;
					push @$items, @albums;
				}
			}	
		}

		if ($label->{top_tracks}) {
			my @tracks = map { _trackItem($client, $_, 1) } @{$label->{top_tracks}};
			if (scalar @tracks) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_TOP_TRACKS'),
					image => 'html/images/playlists.png',
					type  => 'header',
					items => \@tracks,
				};
				push @$items, @tracks;
			}
		}

		if ($label->{playlists}) {
			my @playlists = map { _playlistItem($_, 1) } @{$label->{playlists}->{items}};
			if (scalar @playlists) {
				my $name = cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS');
				my $item = {
					image => 'html/images/playlists.png',
					type  => 'header',
				};
				if ($label->{playlists}->{has_more}) {
					$name .= "	(" . cstring($client, 'PLUGIN_QOBUZ_ALL') . ")";
					$item->{url} = \&QobuzGetList;
					$item->{passthrough} = [{ type => 'playlists', cmd => 'label/getPlaylists', args => { label_id => $labelId, sort => 'release_date', order => 'desc' } }];
				}
				$item->{name} = $name;
				push @$items, $item;
				push @$items, @playlists;
			}	
		}

		if ($label->{description}) {
			push @$items, {
				name  => cstring($client, 'DESCRIPTION'),
				type  => 'header',
				items => [{ name => _stripHTML($label->{description}), type => 'textarea' }],
			};
		}

		$cb->({ items => $items });
	}, $args);
}

#Sven 2025-11-05 - a list of all awards 
sub QobuzAwardsExplore {
	my ($client, $cb, $params, $args) = @_;

	return if QobuzValidateWebToken(@_);

	$args->{cmd}  = 'award/explore'; # 'list'; 
	$args->{args} = { limit => 50 };

	getAPIHandler($client)->getData(sub {
		my $awards = shift;

		$cb->( {
			items => [
				map {
					{
						name  => $_->{name},
						line2 => $_->{magazine}->{name},
						image => $_->{image} || 'plugins/Qobuz/html/images/awards.png',
						type  => 'menu', #Sven - view type
						url   => \&QobuzAwardPage,
						passthrough => [ $_->{id} ],
					}
				} @{$awards->{items}}
			] } );
	}, $args);
}

#Sven 2025-11-05 - the award info page
sub QobuzAwardPage {
	my ($client, $cb, $params, $awardId) = @_;

	return if QobuzValidateWebToken(@_);

	my $args = { cmd => 'award/page', args => { award_id => $awardId } };

	getAPIHandler($client)->getData(sub {
		my $award = shift;

		my $items = [];

		if ($award->{releases}) {
			for my $releases (@{$award->{releases}}) {		
				my @albums = map { _albumItem($client, $_) } @{$releases->{data}->{items}};
				my $name   = ($releases->{id} eq 'all') ? cstring($client, 'PLUGIN_QOBUZ_REL_ALBUM') : uc($releases->{id});
				if (scalar @albums) {
					my $item = {
						image => 'html/images/albums.png',
						type  => 'header',
					};
					if ($releases->{data}->{has_more}) {
						$name .= "	(" . cstring($client, 'PLUGIN_QOBUZ_ALL') . ")";
						my $cmd;
						if ($releases->{id} eq 'all' ) { $cmd = 'award/getAlbums'; }
						if ($cmd) {
							$item->{url} = \&QobuzGetAlbums;
							$item->{passthrough} = [{ cmd => $cmd, args => { award_id => $awardId, sort => 'release_date', order => 'desc' } }];
						}
					}
					$item->{name} = $name;
					push @$items, $item;
					push @$items, @albums;
				}
			}	
		}

		if ($award->{playlists}) {
			my @playlists = map { _playlistItem($_, 1) } @{$award->{playlists}->{items}};
			if (scalar @playlists) {
				my $name = cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS');
				my $item = {
					image => 'html/images/playlists.png',
					type  => 'header',
					items => \@playlists,
				};
				$item->{name} = $name;
				push @$items, $item;
				push @$items, @playlists;
			}	
		}

		if ($award->{description}) {
			push @$items, {
				name  => cstring($client, 'DESCRIPTION'),
				type  => 'header',
				items => [{ name => _stripHTML($award->{description}), type => 'textarea' }],
			};
		}

		$cb->({ items => $items });
	}, $args);
}

#Sven 2022-05-18, 2025-09-17 v30.6.2
sub QobuzAlbums {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId} || '';

	my @types = (
		#['new-releases',		'PLUGIN_QOBUZ_NEW_RELEASES'], #Sven 2025-11-03 - macht keinen großen Sinn
		['new-releases-full',	'PLUGIN_QOBUZ_NEW_RELEASES'], # entspricht der Liste aus den Apps.
		['favorite/getNewReleases',	'PLUGIN_QOBUZ_RELEASE_RADAR', 'type', 'artists'], #Sven 2025-10-21 - release radar
		['ideal-discography',	'PLUGIN_QOBUZ_IDEAL_DISCOGRAPHY'],
		['qobuzissims',			'PLUGIN_QOBUZ_QOBUZISSIMS'],
		['discover/albumOfTheWeek',	'PLUGIN_QOBUZ_ALBUMS_OF_THE_WEEK'], #Sven 2025-10-15 - albums of the week
		['most-streamed',		'PLUGIN_QOBUZ_MOST_STREAMED'],
		['press-awards',		'PLUGIN_QOBUZ_PRESS'],

		['editor-picks',		'PLUGIN_QOBUZ_EDITOR_PICKS'],
		['best-sellers',		'PLUGIN_QOBUZ_BESTSELLERS'],
		['most-featured',		'PLUGIN_QOBUZ_MOST_FEATURED'],
		#['new-releases-full',	'PLUGIN_QOBUZ_NEW_RELEASES_FULL'],
		#['recent-releases',	'PLUGIN_QOBUZ_RECENT_RELEASES'],
		#['re-release-of-the-week',	're-release-of-the-week'],
		#['harmonia-mundi',		'harmonia-mundi'],
		#['universal-classic',	'universal-classic'],
		#['universal-jazz',		'universal-jazz'],
		#['universal-jeunesse',	'universal-jeunesse'],
		#['universal-chanson',	'universal-chanson'],
	);
	
	my $items = [];
	
	#Sven 2025-09-17
	push @$items, {
		name  => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECT'),
		image => 'html/images/genres.png',
		type  => 'menu', #Sven - view type
		url  => \&QobuzGenreSelection,
		passthrough => [{ filter => 'genreFilter' }],
	} unless ($genreId);
	
	foreach (@types) { 
		my $params = { cmd => $$_[0], args => {} };
		if (@$_ > 2) {
			$params->{args}->{$$_[2]} = $$_[3];
			$params->{showDate} = 1;
		}	
		push @$items, {
			name => cstring($client, $$_[1]),
			url  => ($$_[0] =~ /\//) ? \&QobuzGetAlbums : \&QobuzFeaturedAlbums, #Sven 2025-10-21 - albums of the week, release radar
			image => 'html/images/albums.png',
			type  => 'albums', #Sven - view type
			passthrough => [$params]
		};
	};
	
	$cb->({ items => $items });
}

#Sven 2025-12-27
sub QobuzSearch {
	my ($client, $cb, $params, $args) = @_;

	#$log->error(Data::Dump::dump($params));
	#$log->error(Data::Dump::dump($args));

	$args ||= {};
	$params->{search} ||= $args->{q};
	my $type   = lc($args->{type} || '');
	my $search = lc($params->{search});

	$args->{limit} ||= 10 unless $type;

	getAPIHandler($client)->search(sub {
		my $searchResult = shift;

		if (!$searchResult) {
			$cb->();
			return;
		}

		my $artists   = [ map { _artistItem($client, $_, 1) } @{$searchResult->{artists}->{items} || []} ];
	
		my $albums    = getAlbumsGrouped( $client, $searchResult->{albums}, $params->{search}, $args );

		my $tracks    = [ map { _trackItem($client, $_, $params->{isWeb}) } @{$searchResult->{tracks}->{items} || []} ];
	
		my $playlists = [ map { _playlistItem($_, $params->{isWeb}) } @{$searchResult->{playlists}->{items} || []} ];
	
		my $items = [];

		my $count = scalar @$artists;
		my $total = $searchResult->{artists}->{total};
		if ($count) {
			push @$items, {
				name  => cstring($client, 'ARTISTS') . " ($count/$total)",
				image => 'html/images/artists.png',
				type => 'header', 
				url  => \&QobuzSearch,
				passthrough => [{ q => $search, type => 'artists' }]
			};
			push @$items, @$artists;
		}

		push @$items, @$albums if scalar @$albums;

		$count = scalar @$tracks;
		$total = $searchResult->{tracks}->{total};
		if ($count) {
			push @$items, {
				name  => cstring($client, 'SONGS') . " ($count/$total)",
				image => 'html/images/playlists.png',
				type => 'header',
				playall => 1,
				url  => \&QobuzSearch,
				passthrough => [{ q => $search, type => 'tracks' }]
			};
			push @$items, @$tracks;
		}
	
		$count = scalar @$playlists;
		$total = $searchResult->{playlists}->{total};
		if ($count) {
			push @$items, {
				name  => cstring($client, 'PLAYLISTS') . " ($count/$total)",
				image => 'html/images/playlists.png',
				type => 'header',
				url  => \&QobuzSearch,
				passthrough => [{ q => $search, type => 'playlists' }]
			};
			push @$items, @$playlists;
		}
	
		if (scalar @$items == 1) {
			$items = $items->[0]->{items};
		}

		$cb->({
			items => $items
		});
	}, $search, $type, $args);
}
	
#Sven 2025-12-27
sub getAlbumsGrouped {
	my ($client, $results, $search, $args) = @_;
	
	my $releases = [];
	
	if ($results) {
		my $total = $results->{total};

		my $groupByReleaseType = $prefs->get('groupReleases');
		
		unless ($groupByReleaseType) {
			for my $album ( @{$results->{items} || []} ) {
				push @$releases, _albumItem($client, $album);
			}
			my $count = scalar @$releases;
			unshift @$releases, {
				name => cstring($client, 'ALBUMS') . " ($count/$total)",
				image => 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-album.png',
				type => 'header',
				playall => 1,
				url  => \&QobuzSearch,
				passthrough => [{ q => $search, type => 'albums' }]
				};
			return $releases
		};
		
		my $albums = [];
		my $numAlbums = 0;
		my $eps = [];
		my $numEps = 0;
		my $singles = [];
		my $numSingles = 0;
		
		# group by release type
		for my $album ( @{$results->{items}} ) {
			if ($album->{duration} >= 1800 || $album->{tracks_count} > 6) {
				$album->{release_type} = ALBUM;
				$numAlbums++;
			} elsif ($album->{tracks_count} < 4) {
				$album->{release_type} = SINGLE;
				$numSingles++;
			} else {
				$album->{release_type} = EP;
				$numEps++;
			}
		}

		my $filter = $args->{relType} || '';
		if ($filter) {
			for my $album ( @{$results->{items}} ) {
				push @$releases, _albumItem($client, $album) if $album->{release_type} eq $filter;
			}
			return $releases;
		}

		$results->{items} = [
			sort { $a->{release_type} cmp $b->{release_type} } @{$results->{items} || []}
		];

		my $lastReleaseType = "";
		
		for my $album ( @{$results->{items}} ) {
			my $albumItem = _albumItem($client, $album);

			if ($album->{release_type} eq ALBUM) {
				push @$albums, $albumItem;
			} elsif ($album->{release_type} eq EP) {
				push @$eps, $albumItem;
			} elsif ($album->{release_type} eq SINGLE) {
				push @$singles, $albumItem;
			}

			if ($album->{release_type} ne $lastReleaseType) {
				$lastReleaseType = $album->{release_type};
				my $relType = "";
				my $relNum = 0;
				my $relItems;
				my $relIcon = "";

				if ($lastReleaseType eq ALBUM) {
					$relType = cstring($client, 'ALBUMS');
					$relNum = $numAlbums;
					$relItems = $albums;
					$relIcon = 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-album.png';
				} elsif ($lastReleaseType eq EP) {
					$relType = cstring($client, 'RELEASE_TYPE_EPS');
					$relNum = $numEps;
					$relItems = $eps;
					$relIcon = 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-ep.png';
				} elsif ($lastReleaseType eq SINGLE) {
					$relType = cstring($client, 'RELEASE_TYPE_SINGLES');
					$relNum = $numSingles;
					$relItems = $singles;
					$relIcon = 'plugins/Qobuz/html/images/Qobuz_MTL_svg_release-single.png';
				} else {
					$relType = "Unknown";  #should never occur
				}

				push @$releases, {
					name => "$relType ($relNum/$total)",
					image => $relIcon,	
					type => 'header',
					playall => 1,
					url  => \&QobuzSearch,
					passthrough => [{ q => $search, type => 'albums', relType => $lastReleaseType }]
				};
			}
			push @$releases, $albumItem;
		}
	}

	return $releases;
}

sub browseArtistMenu {
	my ($client, $cb, $params, $args) = @_;

	my $artistId = $params->{artist_id} || $args->{artist_id};
	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {
		if (my ($extId) = grep /qobuz:artist:(\d+)/, @{$artistObj->extIds}) {
			($args->{artistId}) = $extId =~ /qobuz:artist:(\d+)/;
			return QobuzArtist($client, $cb, undef, { artistId => $args->{artistId} });
		}
		else {
			$args->{q}    = $artistObj->name;
			$args->{type} = 'artists';

			QobuzSearch($client, sub {
				my $items = shift || { items => [] };

				my $id;
				if (scalar @{$items->{items}} == 1) {
					$id = $items->{items}->[0]->{passthrough}->[0]->{artistId};
				}
				else {
					my @ids;
					$items->{items} = [ map {
						push @ids, $_->{passthrough}->[0]->{artistId};
						$_;
					} grep {
						Slim::Utils::Text::ignoreCase($_->{name} ) eq $artistObj->namesearch
					} @{$items->{items}} ];

					if (scalar @ids == 1) {
						$id = shift @ids;
					}
				}

				if ($id) {
					$args->{artistId} = $id;
					return QobuzArtist($client, $cb, $params, $args);
				}

				$cb->($items);
			}, $params, $args);

			return;
		}
	}

	$cb->([{
		title => cstring($client, 'EMPTY'),
		#type  => 'text' #Sven 2025-12-14 - Verursacht beim Anklicken einen Sprung ins Hauptmenu als Untermenü. absurdes Verhalten, nur wenn es der erste Menüpunkt ist.
	}]);
}

#Sven 2025-10-30
sub QobuzArtist {
	my ($client, $cb, $params, $args) = @_;

	my $api = getAPIHandler($client);

	$api->getArtistPage( sub {
		my $artist = shift;

		my $items = [];

		my $funcs = [];
		
		if ($artist->{biography}) {
			push @$funcs, {
				name  => cstring($client, 'PLUGIN_QOBUZ_BIOGRAPHY'),
				image => $artist->{image} || $api->getArtistPicture($artist->{id}),
				type  => 'menu',
				items => [{
					name => _stripHTML($artist->{biography}->{content}),
					type => 'textarea',
				}],
			};
		}
		else { #Sven
			push @$funcs, {
				name  => $artist->{name},
				image => $artist->{image} || $api->getArtistPicture($artist->{id}),
				#type  => 'text' #Sven 2025-12-14 - Verursacht beim Anklicken einen Sprung ins Hauptmenu als Untermenü. absurdes Verhalten, nur wenn es der erste Menüpunkt ist.
			};
		}	

		#Sven 2025-10-23 
		push @$funcs, {
			name => cstring($client, 'PLUGIN_QOBUZ_RADIO'),
			image => 'html/images/radio.png',
			type => 'menu', #'link',
			url  => \&QobuzRadio,
			passthrough => [{ artist_id => $artist->{id} }]
		};

		#Sven 2020-03-30
		push @$funcs, {
			name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
			image => 'html/images/favorites.png',
			type => 'menu', #'link',
			url  => \&QobuzManageFavorites,
			passthrough => [{artistId => $artist->{id}, artist => $artist->{name}}]
		};

		push @$items, {
			name => $artist->{name},	
			image => 'html/images/artists.png',
			type  => 'header',
			items => $funcs,
		};
		push @$items, @$funcs;	
		
		if ($artist->{top_tracks}) {
			my @tracks = map { _trackItem($client, $_, $params->{isWeb}) } @{$artist->{top_tracks}};
			if (scalar @tracks) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_TOP_TRACKS'),
					image => 'html/images/playlists.png',
					type  => 'header',
					items => \@tracks,

				};
				push @$items, @tracks;
			}
		}

		if ($artist->{similar_artists}) {
			my @artists = map { _artistItem($client, $_, 1) } @{$artist->{similar_artists}->{items}};
			if (scalar @artists) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_SIMILAR_ARTISTS'),
					image => 'html/images/artists.png',
					type  => 'header',
					items => \@artists,
				};
				push @$items, @artists;
			}
		}

		if ($artist->{last_release}) {
			my $album = _albumItem($client, $artist->{last_release});
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_LASTRELEASE'),
				image => 'html/images/albums.png',
				type  => 'header', 
				items => [$album],
			};
			push @$items, $album;
		}

		if ($artist->{releases}) {
			for my $releases (@{$artist->{releases}}) {		
				my @albums = map { _albumItem($client, $_) } @{$releases->{items}};
				if (scalar @albums) {
					my $item = {
						name  => cstring($client, 'PLUGIN_QOBUZ_REL_'. uc($releases->{type})),
						image => 'html/images/albums.png',
						type  => 'header',
					};
					if ($releases->{has_more}) {
						$item->{url} = \&QobuzGetAlbums;
						$item->{passthrough} = [{ cmd => "artist/getReleasesList", args => { artist_id => $artist->{id}, release_type => $releases->{type}, track_size => 0, sort => 'release_date', genre_ids => '' } }];
					}
					else { $item->{items} = \@albums; }
					push @$items, $item;
					push @$items, @albums;		
				}				
			}	
		}

		if ($artist->{tracks_appears_on}) {
			my @tracks = map { _trackItem($client, $_, $params->{isWeb}) } @{$artist->{tracks_appears_on}};
			if (scalar @tracks) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_TRACKSAPPEARSON'),
					image => 'html/images/playlists.png',
					type  => 'header',
					items => \@tracks,
				};
				push @$items, @tracks;		
			}	
		}

		if ($artist->{playlists}) {
			my @playlists = map { _playlistItem($_, $params->{isWeb}) } @{$artist->{playlists}->{items} || []};
			if (scalar @playlists) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS'),
					image => 'html/images/playlists.png',
					type  => 'header',
					items => \@playlists,
				};
				push @$items, @playlists;
			}	
		}

		$cb->({ items => $items });

	}, $args->{artistId}); 
}

#Sven 2025-09-15 v30.6.2
sub QobuzGenreSelection {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = ''; $args->{genreId} || '';
	my $genreFilter = $args->{filter};
	
	getAPIHandler($client)->getGenres(sub {
		my $genres = shift;

		if (!$genres) {
			$log->error("Get genres failed");
			return;
		}

		my $items = []; #Sven 2020-03-27

		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECTALL'),
			image => 'html/images/genres.png',
			url => \&QobuzGenreToggle,
			passthrough => [{ genreId => '', filter => $genreFilter }],
			nextWindow => 'refresh',
		};

		for my $genre ( @{$genres->{genres}->{items}} ) {
			push @$items, { 
				name => $genre->{name},
				image => _isGenreSet($genre->{id}, $genreFilter) ? 'plugins/Qobuz/html/images/checkbox-checked_svg.png' : 'plugins/Qobuz/html/images/checkbox-empty_svg.png',
				url => \&QobuzGenreToggle,
				passthrough => [{ genreId => $genre->{id}, filter => $genreFilter }],
				#type => 'link', #Sven
				nextWindow => 'refresh',
			};
		}

		$cb->({
			items => $items
		})
	}, $genreId);
}

#Sven 2025-09-15
sub _isGenreSet {
	my ($genreId, $Filter) = @_;
	
	my $genreFilter = $prefs->get($Filter) || '##';
	my $result = 1;
	
	unless ($genreFilter eq '##') { 
		$genreId = '#' . $genreId . '#';
		$result = 0 unless ($genreFilter=~/$genreId/);
	}
	return $result;
}

#Sven 2025-09-16
sub _getGenres {
	my ($filter) = @_;
	
	unless ($filter) { $filter = 'genreFilter'};
	my $genreFilter = $prefs->get($filter) || '##';
	
	$genreFilter = substr($genreFilter, 1, length($genreFilter)-2);
	$genreFilter=~s/##/,/g;
	
	return $genreFilter;
}

#Sven 2025-09-17
sub QobuzGenreToggle {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId} || '';
	my $genreFilter = $prefs->get($args->{filter}) || '##';

	$genreId = '#' . $genreId . '#';
	if ($genreFilter eq '##' || $genreId eq '##') { $genreFilter = $genreId; }
	else {
		unless ($genreFilter=~s/$genreId//) { $genreFilter .= $genreId; }
	};
	$prefs->set($args->{filter}, $genreFilter);

	$cb->();
}

sub QobuzFeaturedAlbums {
	my ($client, $cb, $params, $args) = @_;
	my $type    = $args->{cmd};
	my $genreId = $args->{args}->{genre_Ids};
	
	unless (defined $genreId) { $genreId = _getGenres(); }; #Sven 2025-09-16 v30.6.2
	
	getAPIHandler($client)->getFeaturedAlbums(sub {
		my $albums = shift;

		my $items = [];

		foreach my $album ( @{$albums->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({ items => $items })
	}, $type, $genreId);
}

sub QobuzUserPurchases {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserPurchases(sub {
		my $searchResult = shift;

		my $items = [];

		for my $album ( @{$searchResult->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			push @$items, _trackItem($client, $track, 1);
		}

		$cb->( {
			items => $items
		} );
	});
}

#Sven 2022-05-20, 2023-02-11 v2.8.1, 2025-09-17 v30.6.2 filtern nach Genre
sub QobuzUserFavorites {
	my ($client, $cb, $params, $type) = @_;

	getAPIHandler($client)->getUserFavorites(sub {
		my $favorites = shift;
		
		my $genreFilter = 'genreFavsFilter';
		my $items = [];
		my @aItem = @{$favorites->{$type}->{items}};
		if (scalar @aItem) {
			my $itemFn = ($type eq 'albums') ? \&_albumItem : ($type eq 'tracks') ? \&_trackItem : \&_artistItem;
			foreach ( @aItem ) {
				my $push = 1;
				if ($type eq 'albums') { $push = _isGenreSet($_->{genrePath}[0], $genreFilter) }
				elsif ($type eq 'tracks') { $push = _isGenreSet($_->{album}->{genre}->{path}[0], $genreFilter) }
				push @$items, $itemFn->($client, $_, 1) if $push;
			};

			my $sortFavsAlphabetically = ($type eq 'artists' && $prefs->get('sortArtistsAlpha')) ? 1 : $prefs->get('sortFavsAlphabetically') || 0;
			if ( $sortFavsAlphabetically ) {
				my $sortFields = { albums => ['line1', 'name'], artists => ['name', 'name'], tracks => ['line1', 'line2'] };
				my $sortField  = $sortFields->{$type}[$sortFavsAlphabetically - 1];
				@$items = sort { Slim::Utils::Text::ignoreCaseArticles($a->{$sortField}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{$sortField}) } @$items;
			};
		}

		$cb->( {
			items => $items
		} );
	}, $type, 0);
}

#Sven 2022-05-17 look at 'Info multi AP-Calls.pm'
sub QobuzManageFavorites {
	my ($client, $cb, $params, $args) = @_;
	
	my $status = { artist => -1, album => -1, track => -1};
	my $call = {};
	
	my $callback = sub {
		my $result = shift;
		
		if ($result) {
			$status->{$result->{type}} = $result->{status};
			delete($call->{$result->{type}});
		}
		
		return if (scalar keys %$call > 0);
		
		my $items = [];
		
		if ($status->{artist} > -1) {
			push @$items, {
				name => cstring($client, $status->{artist} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', cstring($client, 'ARTIST') . " '" . $args->{artist} . "'"),
				#name => cstring($client, 'ARTIST') . ':' . $args->{artist},
				#line2 => cstring($client, $status->{artist} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $args->{artist}),
				image => 'html/images/favorites.png', #$status->{artist} ? 'html/images/favorites_remove.png' : 'html/images/favorites.png',
				type => 'link',
				url  => \&QobuzSetFavorite,
				passthrough => [{ artist_ids => $args->{artistId}, add => !$status->{artist} }],
				nextWindow => 'grandparent'
			};
		}
		
		if ($status->{album} > -1) {
			my $albumname = cstring($client, 'ALBUM') . " '" . $args->{album} . ($args->{artist} ? ' ' . cstring($client, 'BY') . ' ' . $args->{artist} : '') . "'";
			push @$items, {
				name => cstring($client, $status->{album} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $albumname),
				#name => $args->{album},
				#line2 => cstring($client, $status->{album} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $args->{album}),
				image => 'html/images/favorites.png', #$status->{album} ? 'html/images/favorites_remove.png' : 'html/images/favorites.png',
				type => 'link',
				url  => \&QobuzSetFavorite,
				passthrough => [{ album_ids => $args->{albumId}, add => !$status->{album} }],
				nextWindow => 'grandparent'
			};
		};
		
		if ($status->{track} > -1) {
			push @$items, {
				name => cstring($client, $status->{track} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', cstring($client, 'TRACK') . " '" . $args->{title} . "'"),
				#name => $args->{title},
				#line2 => cstring($client, $status->{track} ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $args->{title}),
				image => 'html/images/favorites.png', # $status->{track} ? 'html/images/favorites_remove.png' : 'html/images/favorites.png',
				type => 'link',
				url  => \&QobuzSetFavorite,
				passthrough => [{ track_ids => $args->{trackId}, add => !$status->{track} }],
				nextWindow => 'grandparent'
			};
		}
		
		$cb->( { items => $items } );
	};
	
	my $api = getAPIHandler($client);
	
	if ($args->{artist} && $args->{artistId}) {
		$call->{artist} = 1;
		$api->getFavoriteStatus($callback, { item_id => $args->{artistId}, type => 'artist' });
	}
	
	if ($args->{album}  && $args->{albumId}) {
		$call->{album} = 1;
		$api->getFavoriteStatus($callback, { item_id => $args->{albumId}, type => 'album' });
	}
	
	if ($args->{title}  && $args->{trackId}) {
		$call->{track} = 1;
		$api->getFavoriteStatus($callback, { item_id => $args->{trackId},  type => 'track' });
	}
}

#Sven 2022-05-13
sub QobuzSetFavorite {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->setFavorite(sub { $cb->(); }, $args);
}

#Sven 2022-05-23, 2025-11-03
sub QobuzUserPlaylists {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserPlaylists(sub {
		_playlistCallback(shift, $cb, $params->{isWeb}, 'sort'); #Sven 2025-11-03
	}, $args); #Sven 2022-05-23
}

#Sven 2025-09-17 v30.6.2
sub QobuzPlaylistTags {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId};
	my $type    = $args->{type} || 'editor-picks';
	my $api     = getAPIHandler($client);

	$api->getTags(sub {
		my $tags = shift;

		if ($tags && ref $tags) {
			my $lang = lc(preferences('server')->get('language'));

			my @items = map {
				{
					name => $_->{name}->{$lang} || $_->{name}->{en},
					image => 'html/images/playlists.png',
					type  => 'playlists', #Sven
					url   => \&QobuzPublicPlaylists,
					passthrough => [{
						genreId => $genreId, 
						tags => $_->{id},
						type => $type
					}]
				};
			} @$tags;

			unshift @items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_ALL'),
				image => 'html/images/playlists.png',
				type  => 'playlists',
				url   => \&QobuzPublicPlaylists,
				passthrough => [{
					genreId => $genreId, 
					tags => 'all',
					type => $type
				}]
			};

			unshift @items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_GENRE_SELECT'),
				image => 'html/images/genres.png',
				type  => 'menu', #Sven - view type
				url  => \&QobuzGenreSelection,
				passthrough => [{ filter => 'genreFilter' }],
			} unless ($genreId);

			$cb->( {
				items => \@items
			} );
		}
		else {
			$cb->();
		} 
	});
}

#Sven 2025-09-17 v30.6.2
sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId};
	my $tags    = $args->{tags} || '';
	my $type    = $args->{type} || 'editor-picks';

	unless ($genreId) { $genreId = _getGenres(); };
	
	getAPIHandler($client)->getPublicPlaylists(
		sub {
			_playlistCallback(shift, $cb, $params->{isWeb});
		}, $type, $genreId, ($tags eq 'all') ? '' : $tags);
}

#Sven 2022-05-23
sub _playlistCallback {
	my ($searchResult, $cb, $isWeb, $cmd) = @_;

	$searchResult = ($searchResult->{playlists}) ? $searchResult->{playlists} : $searchResult->{similarPlaylist}; #Sven 2022-05-23

	my $playlists = [];

	for my $playlist ( @{$searchResult->{items}} ) {
		next if defined $playlist->{tracks_count} && !$playlist->{tracks_count};
		push @$playlists, _playlistItem($playlist, $isWeb);
	}

	if ($cmd eq 'sort') {
		my $sortPlaylists = $prefs->get('sortPlaylists') || 0;
		if ( $sortPlaylists ) {
			@$playlists = sort { Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name}) } @$playlists;
		};
	}

	$cb->( {
		items => $playlists
	} );
}

#Sven 2022-05-23
sub QobuzSimilarPlaylists {
	my ($client, $cb, $params, $playlistId) = @_;
	
	getAPIHandler($client)->getSimilarPlaylists(sub {
		_playlistCallback(shift, $cb, $params->{isWeb});
	}, $playlistId);
}

#Sven 2022-05-11 called from _playlistItem
sub QobuzPlaylistItem {
	my ($client, $cb, $params, $playlist, $args) = @_;

	my $items = []; #ref array

	push @$items, {
		name  => $args->{name},
		name2 => $args->{owner},
		image => $args->{image},
		url   => \&QobuzPlaylistGetTracks,
		passthrough => [ $playlist->{id} ],
		type  => 'playlist',
		favorites_url  => 'qobuz://playlist:' . $playlist->{id} . '.qbz', #fügt dem Contextmenu"In Favoriten speichern" hinzu
		favorites_type => 'playlist',
	};

	push @$items, {
		name => _countDuration($client, $playlist->{tracks_count}, $playlist->{duration}),
		type => 'text',
	};

	my $temp = $playlist->{genres};
	if ($temp && ref $temp && scalar @$temp) {
		my $genre_s = '';
		map { $genre_s .= ', ' . $_->{name} } @$temp;
		push @$items, { name  => substr($genre_s, 2), label => 'GENRE', type => 'text' };
	}

	my $temp = $playlist->{featured_artists}; # is a ref of an array
	if ($temp && ref $temp && scalar @$temp) {
		my @artists = map { _artistItem($client, $_, 1) } @$temp;
		push @$items, { name => cstring($client, 'ARTISTS'), items => \@artists } if scalar @artists; #Ausgewählte Künstler
	}

	if ($playlist->{description}) {
		push @$items, {
			name  => cstring($client, 'DESCRIPTION'),
			items => [{ name => _stripHTML($playlist->{description}), type => 'textarea'}],
		};
	}

	#Sven 2022-05-23 created_at ist vom Datum her immer gleich public_at, die Uhrzeit in public_at ist immer 00:00:00.
	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($playlist->{created_at}),
		type  => 'text'
		} if $playlist->{created_at};

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_UPDATED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($playlist->{updated_at}),
		type  => 'text'
		} if $playlist->{updated_at};

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_SIMILAR_PLAYLISTS'),
		type => 'playlists', #'link',
		url  => \&QobuzSimilarPlaylists,
		passthrough => [{ playlist_id => $playlist->{id} }],
		} if $playlist->{stores};

	if ($playlist->{owner}->{id} eq getAPIHandler($client)->userId) { #Sven
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_REMOVE_PLAYLIST'),
			items => [{
				name => $args->{name} . ' - ' . cstring($client, 'PLUGIN_QOBUZ_REMOVE_PLAYLIST'),
				type => 'link',
				url  => \&QobuzPlaylistCommand,
				passthrough => [{ playlist_id => $playlist->{id}, command => 'delete' }],
				nextWindow => 'grandparent'
			}],	
		};
	}
	else {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SUBSCRIPTION'),
			type => 'link',
			url  => \&QobuzPlaylistSubscription,
			passthrough => [ $playlist ],
		};
	}
	$cb->({ items => $items });
}

#Sven 2022-05-14
sub QobuzPlaylistSubscription {
	my ($client, $cb, $params, $playlist) = @_;
	
	getAPIHandler($client)->getUserPlaylists(sub {
		my $playlists = shift;
		my $isSubscribed;
		
		if ($playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists}) {
			my $playlistId = $playlist->{id};
			foreach (@{$playlists->{playlists}->{items}}) {
				if ($isSubscribed = ($_->{id} eq $playlistId)) { last };
			};
		};
		
		my $item = {
			name => $playlist->{name} . ' - ' . cstring($client, $isSubscribed ? 'PLUGIN_QOBUZ_UNSUBSCRIBE' : 'PLUGIN_QOBUZ_SUBSCRIBE'),
			#line2 => cstring($client, $subscribed ? 'PLUGIN_QOBUZ_UNSUBSCRIBE' : 'PLUGIN_QOBUZ_SUBSCRIBE'), #cstring($client, 'ALBUM')),
			image => 'html/images/favorites.png', #$isFavorite ? 'html/images/favorites_remove.png' : 'html/images/favorites_add.png',
			type => 'link',
			url  => \&QobuzPlaylistCommand,
			passthrough => [{ playlist_id => $playlist->{id}, command => ($isSubscribed ? 'unsubscribe' : 'subscribe') }],
			nextWindow => 'grandparent' #'parent' ist zu wenig, 'grandparent' spring zurück auf die Liste
		};
		
		$cb->( { items => [$item] } );
	});
}

#Sven 2022-05-14
sub QobuzPlaylistCommand {
	my ($client, $cb, $params, $args) = @_;
	
	getAPIHandler($client)->doPlaylistCommand(sub { $cb->() }, $args);
}

#Sven 2019-03-19
#Slim::Utils::DateTime::timeFormat(),
sub _sec2hms {
	my $seconds = @_[0] || '0';

	my $minutes   = int($seconds / 60);
	my $hours     = int($minutes / 60);
	return $hours eq 0 ? sprintf('%02s:%02s', $minutes, $seconds % 60) : sprintf('%s:%02s:%02s', $hours, $minutes % 60, $seconds % 60); 
}

#Sven 2019-04-11, 2022-05-10
sub _quality {
	my $meta = @_[0];
	
	$meta = $meta->{tracks}->{items}[0] if $meta->{tracks}; #Sven 2020-12-31 liest die Qualität aus dem 1. Track wenn $meta ein Album und kein Track ist
	
	my $channels = $meta->{maximum_channel_count};
	if ($channels) {
		if ($channels eq 2) { $channels = '' } # 'Stereo'
		elsif ($channels eq 1) { $channels = ' - Mono' }
		else { $channels = ' - ' . $channels . ' Kanal' }
		
		return $meta->{maximum_bit_depth} . '-Bit ' . $meta->{maximum_sampling_rate} . 'kHz' . $channels;
	}
	return $meta->{bitrate};
}

#Sven 2022-05-05 shows album infos before playing music, it is an enhanced version.
#Sven 2025-12-13 The album view is now configurable
sub QobuzGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $albumId = $args->{album_id};
	
	my $api = getAPIHandler($client);
	
	$api->getAlbum(sub {
		my $album = shift;
		my $items = [];
		
		if (!$album) {  # the album does not exist in the Qobuz library
			$log->warn("Get album ($albumId) failed");
			$api->getUserFavorites(sub {
				my $favorites = shift;
				my $isFavorite = ($favorites && $favorites->{albums}) ? grep { $_->{id} eq $albumId } @{$favorites->{albums}->{items}} : 0;

				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_ALBUM_NOT_FOUND'),
					#type  => 'text' #Sven 2025-12-14 - Verursacht beim Anklicken einen Sprung ins Hauptmenu als Untermenü. absurdes Verhalten, nur wenn es der erste Menüpunkt ist.
				};

				if ($isFavorite) {  # if it's an orphaned favorite, let the user delete it
					push @$items, {
						name => cstring($client, 'PLUGIN_QOBUZ_REMOVE_FAVORITE', $args->{album_title}),
						url  => \&QobuzSetFavorite,
						image => 'html/images/favorites.png',
						passthrough => [{
							album_ids => $albumId
						}],
						nextWindow => 'parent'
					};
				}

				$cb->({
					items => $items,
				}, @_ );
			}, 'albums', 0); #Sven 2023-10-09
			return;

		} elsif (!$album->{streamable} && !$prefs->get('playSamples')) {  # the album is not streamable
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
				#type  => 'text' #Sven 2025-12-14 - Verursacht beim Anklicken einen Sprung ins Hauptmenu als Untermenü. absurdes Verhalten, nur wenn es der erste Menüpunkt ist.
			};

			$cb->({
				items => $items,
			}, @_ );
			return;
		}

		my $artistname = $album->{artist}->{name} || '';
		my $albumname  = ($artistname && $album->{title} ? $artistname . ' - ' . $album->{title} : $artistname) || '';
		my $conductorname;
		my $albumcredits = $albumname . "\n\n";

		my $totalDuration = 0;
		my $trackNumber = 0;
		my $tracks = [];
		my $works = {};
		my $lastwork = "";
		my $worksfound = 0;
		my $noComposer = 0;
		my $workHeadingPos = 0;
		my $workPlaylistPos = $prefs->get('workPlaylistPosition');
		my $currentComposer = "";
		my $lastComposer = "";
		my $worksWorkId = "";
		my $worksWorkIdE = "";
		my $lastWorksWorkId = "";
		my $discontigWorks;
		my $workComposer;
		my $lastDisc;
		my $discs = {};
		my $performers = {};

		foreach my $track (@{$album->{tracks}->{items}}) {
			_addPerformers($client, $track, $performers);
			$totalDuration += $track->{duration};
			$albumcredits  .= _trackCredits($client, $track) . "\n\n";
			$conductorname  = _getConductor($track) unless ($conductorname);
			my $formattedTrack = _trackItem($client, $track);
			my $work = delete $formattedTrack->{work};

			# create a playlist for each "disc" in a multi-disc set except if we've got works (mixing disc & work playlists would go horribly wrong or at least be confusing!)
			if ( $prefs->get('showDiscs') && $formattedTrack->{media_count} > 1 && !$work ) {
				my $discId = delete $formattedTrack->{media_number};
				$discs->{$discId} = {
					index => $trackNumber,
					title => string('DISC') . " " . $discId,
					image => $formattedTrack->{image},
					tracks => []
				} unless $discs->{$discId};

				push @{$discs->{$discId}->{tracks}}, $formattedTrack;
			}

			if ( $work ) {
				# Qobuz sometimes would f... up work names, randomly putting whitespace etc. in names - ignore them
				my $workId = Slim::Utils::Text::matchCase(Slim::Utils::Text::ignorePunct($work));
				$workId =~ s/\s//g;
				my $displayWorkId = Slim::Utils::Text::matchCase(Slim::Utils::Text::ignorePunct($formattedTrack->{displayWork}));
				$displayWorkId =~ s/\s//g;

				# Unique work identifier, used to keep tracks together even if composer is missing from some, but on the other hand
				# still distinguishing between works with the same name but different composer!
				$currentComposer = $track->{composer}->{name};
				if ( $workId eq $lastwork && (!$lastComposer || !$currentComposer || $lastComposer eq $currentComposer) ) {
					# Stick with the previous value! ($worksWorkId = $worksWorkId;)
				} elsif ( $currentComposer ) {
					$worksWorkId = $displayWorkId;
				} else {
					$worksWorkId = $workId;
				}

				# Extended Work ID: will usually not change, but we need to keep non-contiguous tracks from the same work
				# separate if the user has chosen to integrate playlists with the work titles.
				$worksWorkIdE = $worksWorkId;
				if ( $workPlaylistPos eq "integrated" && $works->{$worksWorkId} ) {
					if ( $worksWorkId ne $lastWorksWorkId ) {
						$discontigWorks->{$worksWorkId} = $worksWorkId . $trackNumber;
					}
					if ( $discontigWorks->{$worksWorkId} ) {
						$worksWorkIdE = $discontigWorks->{$worksWorkId};
					}
				}

				if ( !$works->{$worksWorkIdE} ) {
					$works->{$worksWorkIdE} = {   # create a new work object
						index => $trackNumber,		# index of first track in the work
						title => $formattedTrack->{displayWork},
						tracks => []
					} ;
				}

				# Create new work heading, except when the user has chosen integrated playlists - in that case
				# the work-playlist headings will be spliced in later.
				if ( ( $workId ne $lastwork ) || ( $lastComposer && $currentComposer && $lastComposer ne $currentComposer ) ) {
					$workHeadingPos = push @$tracks,{
						name  => $formattedTrack->{displayWork},
						#type  => 'text' #Sven 2023-10-08 auskommentiert damit das Werk nicht hochgestellt angezeigt wird.
					} unless $workPlaylistPos eq "integrated";

					$noComposer = !$track->{composer}->{name};
					$lastwork = $workId;
				} else {
					$worksfound = 1;   # we found two consecutive tracks with the same work
				}

				push @{$works->{$worksWorkIdE}->{tracks}}, $formattedTrack if $works->{$worksWorkIdE};


				if ($noComposer && $track->{composer}->{name} && $workHeadingPos) {  #add composer to work title if needed
					# Can't update @$items here when using integrated playlists, as there is no work heading in @$items at present.
					if ( $workPlaylistPos ne "integrated" ) {
						@$tracks[$workHeadingPos-1]->{name} = $formattedTrack->{displayWork};
					}
					$works->{$worksWorkIdE}->{title} = $formattedTrack->{displayWork};
					$noComposer = 0;
				}

				# If we're using integrated playlists, save the work title to a temporary structure (including composer if possible -
				# i.e. when there's a composer in at least one of the tracks in the work group).
				if ( $workPlaylistPos eq "integrated" && (!$workComposer->{$worksWorkIdE}->{displayWork} || $track->{composer}->{name}) ) {
					$workComposer->{$worksWorkIdE}->{displayWork} = $formattedTrack->{displayWork};
				}

				$lastComposer = $track->{composer}->{name};

			} elsif ($lastwork ne "") {  # create a separator line for tracks without a work
				push @$tracks,{
					name  => "————————",
					type  => 'text'
				};
				$lastwork = "";
				$noComposer = 0;
			}

			$trackNumber++;
			$lastWorksWorkId = $worksWorkId;

			push @$tracks, $formattedTrack;
		}

		# create a playlist for each "disc" in a multi-disc set except if we've got works (mixing disc & work playlists would go horribly wrong or at least be confusing!)
		if ( $prefs->get('showDiscs') && scalar keys %$discs && !(scalar keys %$works) && _isReleased($album) ) {
			foreach my $disc (sort { $discs->{$b}->{index} <=> $discs->{$a}->{index} } keys %$discs) {
				my $discTracks = $discs->{$disc}->{tracks};

				# insert disc item before the first of its tracks
				splice @$tracks, $discs->{$disc}->{index}, 0, {
					name => $discs->{$disc}->{title},
					image => 'html/images/albums.png', #image => $discs->{$disc}->{image},
					type => 'playlist',
					playall => 1,
					url => \&QobuzWorkGetTracks,
					passthrough => [{
						tracks => $discTracks
					}],
					items => $discTracks
				} if scalar @$discTracks > 1;
			}
		}

		if (scalar keys %$works && _isReleased($album) ) { # don't create work playlists for unreleased albums
			# create work playlists unless there is only one work containing all tracks
			my @workPlaylists = ();
			if ( $worksfound || $workPlaylistPos eq "integrated" ) {   # only proceed if a work with more than 1 contiguous track was found
				my $workNumber = 0;
				foreach my $work (sort { $works->{$a}->{index} <=> $works->{$b}->{index} } keys %$works) {
					my $workTracks = $works->{$work}->{tracks};
					if ( scalar @$workTracks && ( scalar @$workTracks < $album->{tracks_count} || $workPlaylistPos eq "integrated" ) ) {
						if ( $workPlaylistPos eq "integrated" ) {
							# Add playlist as work heading (or just add as text if only one track in the work)
							my $idx = $works->{$work}->{index} + $workNumber;
							my $workTrackCount = @$workTracks;
							if ( $workTrackCount == 1 || $workTrackCount == $album->{tracks_count} ) {
								if ( $worksfound ) {
									splice @$tracks, $idx, 0, {
										name => $workComposer->{$work}->{displayWork},
										image => 'html/images/playlists.png',
									};
								} else {
									splice @$tracks, $idx, 0, {
										name => $workComposer->{$work}->{displayWork},
										type => 'text',
									}
								}
							} else {
								splice @$tracks, $idx, 0, {
									name => $workComposer->{$work}->{displayWork},
									image => 'html/images/playall.png',
									type => 'playlist',
									playall => 1,
									url => \&QobuzWorkGetTracks,
									passthrough => [{
										tracks => $workTracks
									}],
									items => $workTracks
								};
							}
							$workNumber++;
						} else {
							push @workPlaylists, {
								name => $works->{$work}->{title},
								image => 'html/images/playall.png',
								type => 'playlist',
								playall => 1,
								url => \&QobuzWorkGetTracks,
								passthrough => [{
									tracks => $workTracks
								}],
								items => $workTracks
							}
						}
					}
				}
			}
			if ( @workPlaylists ) {
				# insert work playlists according to the user preference
				if ( $workPlaylistPos eq "before" ) {
					unshift @$tracks, @workPlaylists;
				} elsif ( $workPlaylistPos eq "after" ) {
					push @$tracks, @workPlaylists;
				}
			}
		}

		#Page starts here

		#The playlist must not be at the beginning, otherwise the add/play buttons are displayed at the top, but they have no function here.
		#Therefore the genre is displayed first in the first line.
		#Since 2022 that's not true any more, playlist can be the first element.

		
		#Sven 2025-12-13
		my $dptype = $prefs->get('albumViewType');
		if ( $dptype eq "0") {
			#Playlist
			push @$items, {
	#			name  => ($album->{version} ? $album->{title} . ' - ' . $album->{version} : $album->{title}),
				name  => sprintf('%s %s %s', ($album->{version} ? $album->{title} . ' - ' . $album->{version} : $album->{title}), cstring($client, 'BY'), $album->{artist}->{name}),
	#			line1 => $album->{title} || '', 
				line2 => _countDuration($client, $album->{tracks_count}, $totalDuration). ' - (' . _quality($album) . ')',
				image => ref $album->{image} ? $album->{image}->{large} : $album->{image},
				type  => 'playlist',
				items => $tracks,
				favorites_url  => 'qobuz:album:' . $album->{id}, # war ein funktionierender Fix für Material-Skin, dort fehlte bis 2.9.5 der Menüpunkt "In Favoriten speichern" im Contextmenu
				favorites_type => 'playlist', # Standardwert ist 'playlist', sonst 'audio' (für Radios oder Tracks)
			};
		}
		elsif ( $dptype eq "1") {
			$items = $tracks;
		}	
		
		if (!_isReleased($album) ) {
			my $rDate = _localDate($album->{release_date_stream});
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED') . ' (' . $rDate . ')',
				type  => 'text'
			};
		}

		push @$items, { name => $album->{genre}, label => 'GENRE', type  => 'text' };

		my $item = {};
		my $artist_ref = {}; #Referenz auf anonymen Hash

		if ($conductorname) {
			$artist_ref = lc($conductorname) eq lc($artistname) ? { name => $artistname, id => $album->{artist}->{id} } : { name => $conductorname };
			$item = _artistItem($client, $artist_ref);
			$item->{label} = 'CONDUCTOR';
			push @$items, $item;
		}

		if (!$artist_ref->{id} and ($artist_ref = $album->{artist})) { #only if artist != conductor
			if ($artist_ref->{id} != 145383) { # no Various Artists
				$item = _artistItem($client, $artist_ref);
				$item->{label} = 'ARTIST';
				push @$items, $item;
			}
		}

		if ($item = $album->{composer}) {
			if ($item->{id} != 573076 and $item->{id} != $artist_ref->{id}) { #no Various Composers && artist != composer
				$item = _artistItem($client, $item);
				$item->{label} = 'COMPOSER';
				push @$items, $item;
			}
		}

		#Sven 2022-05-05
		my $temp = $album->{artists}; # is a ref of an array
		if ($temp && ref $temp && scalar @$temp > 1) {
			my @artists = map { _artistItem($client, $_, 1) } @$temp;
			push @$items, { name => cstring($client, 'ARTISTS'), items => \@artists } if scalar @artists;
		}

		if ($album->{description}) {
			push @$items, {
				name  => cstring($client, 'DESCRIPTION'),
				items => [{ name => _stripHTML($album->{description}), type => 'textarea' }],
			};
		}

		#Sven 2022-05-24 - Stand heute Januar 24 scheint Focus von Qobuz nicht mehr unterstützt zu werden, items_focus ist immer undef;
		my $focusItems = $album->{items_focus};
		if ($focusItems && ref $focusItems && scalar @$focusItems) {
			my @fItems = map { {
				name => $_->{title},
				image => $_->{image},
				items => [{ name => $_->{accroche}, type => 'textarea' }],
				#url => \&QobuzFocus,
				#passthrough => [ { focus_id => $_->{id} }],
				}
			} @$focusItems;
			push @$items, { name  => cstring($client, 'PLUGIN_QOBUZ_FOCUS'), items => \@fItems } if scalar @fItems;
		}

		#Sven 2022-05-01
		my $awards = $album->{awards};
		if ($awards && ref $awards && scalar @$awards) {
			my @awItems = map { {
				name => Slim::Utils::DateTime::shortDateF($_->{awarded_at}) . ' - ' . $_->{name},
				image => 'html/images/albums.png',
				type => 'albums', #'text',
				url  => \&QobuzAwardPage,
				passthrough => [ $_->{award_id} ],
			 } } @$awards;
			push @$items, { name  => cstring($client, 'PLUGIN_QOBUZ_AWARDS'), items => \@awItems } if scalar @awItems;
		}

		push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'), items => [{ name => $albumcredits, type => 'textarea' }] };

		# Add a consolidated list of all artists on the album
		$items = _albumPerformers($client, $performers, $album->{tracks_count}, $items);

		if ($album->{label} && $album->{label}->{name}) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $album->{label}->{name},
				url   => \&QobuzLabelPage,
				passthrough => [ $album->{label}->{id} ],
				};
		}

		push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($album->{released_at}), type  => 'text' } if $album->{released_at};

		#Sven 2020-03-30
		push @$items, { name => 'Copyright', items => [{ name => _stripHTML($album->{copyright}), type => 'textarea' }] } if $album->{copyright};

		$item = trackInfoMenuBooklet($client, undef, undef, $album);
		push @$items, $item if $item;

		#Sven 2025-11-03 
		if ($album->{albums_same_artist}) {
			#$log->error(Data::Dump::dump($album->{albums_same_artist}));
			my @albums = map { _albumItem($client, $_) } @{$album->{albums_same_artist}->{items}};
			push @$items, { 
				name => cstring($client, 'PLUGIN_QOBUZ_SAMEARTIST'),
				type => 'albums', #Sven - view type
				items => \@albums, 
			} if scalar @albums;
		}	
		
		#Sven 2025-10-25 
		push @$items, { 
			name => cstring($client, 'PLUGIN_QOBUZ_SUGGEST'),
			type => 'albums', #Sven - view type
			url  => \&QobuzGetAlbums,
			passthrough => [{ cmd => 'album/suggest', args => { album_id => $albumId, genre_ids => '' } }]
		};
		
		#Sven 2025-10-23
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_RADIO'),
			type => 'menu', #'link',
			url  => \&QobuzRadio,
			passthrough => [{ album_id => $albumId }]
		};

		#Sven 2020-03-30
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
			type => 'menu', #'link',
			url  => \&QobuzManageFavorites,
			passthrough => [{refalbum => $album, album => $albumname, albumId => $albumId, artist => $artistname, artistId => $album->{artist}->{id}}],
			favorites_url  => 'qobuz:album:' . $album->{id}, # war ein funktionierender Fix für Material-Skin, dort fehlte bis 2.9.5 der Menüpunkt "In Favoriten speichern" im Contextmenu
			favorites_type => 'playlist', # Standardwert ist 'playlist', sonst 'audio' (für Radios oder Tracks)
		};

		#Sven 2025-12-13
		if ( $dptype eq "2") {
			push @$tracks, {
				name => cstring($client, 'PLUGIN_QOBUZ_ALBUM_INFOMENU'),
				type => 'menu', #'link',
				items => $items
			};

			$items = $tracks;
		}	

		$cb->({
			items => $items
		}, @_ ); #calls callback function with all calling parameters

	}, { album_id => $albumId, extra => 'albumsFromSameArtist' } ); # $albumId ); # 
}

sub _addPerformers {
	my ($client, $track, $performers) = @_;

	if (my $trackPerformers = trackInfoMenuPerformers($client, undef, undef, $track)) {
		my $performerItems = $trackPerformers->{items};
		my $mediaNumber = $track->{'media_number'}||1;
		foreach my $item (@$performerItems) {
			$item->{'track'} = $track->{'track_number'};
			$item->{'disc'}  = $mediaNumber;
		}
		push @{$performers->{$mediaNumber}}, @$performerItems;
	}
}

sub _albumPerformers {
	my ($client, $performers, $trackCount, $items) = @_;

	my @uniquePerformers;
	my %seen = ();
	my $tracks;

	foreach my $disc (sort(keys %$performers)) {
		my %discAdded = ();
		foreach my $item (@{$performers->{$disc}}) {
			push @{$tracks->{$item->{'name'}}->{'tracks'}}, " " . cstring($client, 'DISC') . " $disc" . cstring($client, 'COLON') . " " unless $discAdded{$item->{'name'}}++ || scalar keys %$performers == 1;
			push @{$tracks->{$item->{'name'}}->{'tracks'}}, $item->{'track'};
			delete $item->{'track'};
			push(@uniquePerformers, $item) unless $seen{$item->{'name'}}++;
		}
	}

	if ( scalar @uniquePerformers ) {
		foreach my $item (@uniquePerformers) {
			my @tracks = @{$tracks->{$item->{'name'}}->{'tracks'}};
			my $creditCount = scalar @tracks - (scalar keys %$performers == 1 ? 0 : scalar keys %$performers);
			if ( @tracks && scalar $creditCount < $trackCount ) {
				$item->{'name'} .= " ( ";

				# collapse the track list so that, eg, 1,2,3,5,7,8,9,11,12 becomes 1-3, 5, 7-9, 11-12 and add punctuation to make multi-disc albums somewhat intelligible
				# there's probably a much more perly way of doing this...
				my $sep = "-";
				my $o;
				for my $i ( 0 .. $#tracks ) {
					my $currentValue = $tracks[$i];
					my $currentIsNumber = looks_like_number($currentValue);
					my $nextValue = $tracks[$i+1];
					my $nextIsNumber = looks_like_number($nextValue);
					if ( $currentIsNumber && $nextIsNumber && $nextValue == $currentValue+1 ) {
						$o .= "$currentValue$sep" if $sep;
						$sep = undef;
					} else {
						$o .= "$currentValue";
						$sep = "-";
						if ( $currentIsNumber && $nextIsNumber ) {
							$o .= ", ";
						} elsif ( $currentIsNumber && $nextValue && !$nextIsNumber ) {
							$o .= "; ";
						}
					}
				}

				$item->{'name'} .= "$o )";
			}
		}

		my $item = {
			name => cstring($client, 'PLUGIN_QOBUZ_PERFORMERS'),
			items => \@uniquePerformers,
			type => 'actions',
		};
		push @$items, $item;
	}

	return $items;
}

#Sven 2022-05-10 returns a single string with track credits
sub _trackCredits {
	my ($client, $track) = @_;
	my $details;

	if ($track->{track_number}) {
		$details = sprintf("%02s. %s\n\n", $track->{track_number}, $track->{title});
	}
	else { #called from trackInfoMenuPerformer
	  if ($track->{album}) {
      $details = ' - ' . ((ref $track->{album}) ? $track->{album}->{title} : $track->{album});
	  };
		$details = $track->{title} . $details . "\n\n";
	}

	if ($track->{composer}) {
		my $composer = (ref $track->{composer}) ? $track->{composer}->{name} : $track->{composer};
		$details .= ' . ' . cstring($client, 'COMPOSER') . ': ' . $composer . "\n" if $composer;
	}

	$details .= sprintf(" . %s : %s - (%s)\n\n%s\n", cstring($client, 'LENGTH'), _sec2hms($track->{duration}), _quality($track), cstring($client, 'PLUGIN_QOBUZ_CREDITS'));

	map { s/,/: /; $details .= ' . ' . $_ . "\n"; } split(/ - /, $track->{performers});

	return $details;
}

sub _getConductor {
	my $track = shift;
	
    my $temp = $track->{performers};
	my $pos = index($temp, 'Conductor');
	
	if ($pos >= 0) {
		my $name = substr($temp, 0, $pos - 2);
		$pos = rindex($name, ' - ');
		$name = substr($name, $pos+3) if $pos >= 0;
		return $name;
	}
	return "";
}

sub QobuzWorkGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $tracks = $args->{tracks};

	$cb->({
		type => 'playlist',
		playall => 1,
		items => $tracks
	});
}

#Sven 2023-10-07
sub QobuzPlaylistGetTracks {
	my ($client, $cb, $params, $playlistId) = @_;

	getAPIHandler($client)->getPlaylistTracks(sub {
		my $playlist = shift;

		if (!$playlist) {
			$log->error("Get playlist ($playlistId) failed");
			$cb->();
			return;
		}

		my $tracks = [];

		foreach my $track (@{$playlist->{tracks}->{items}}) {
			push @$tracks, _trackItem($client, $track, $params->{isWeb});
		}
		$cb->({
			items => $tracks,
		}, @_ );
	}, $playlistId);
}

#Sven 2020-04-01
sub _albumItem {
	my ($client, $album) = @_;

	my $artist = $album->{artist}->{name} || '';
	my $albumname = $album->{title} || '';
	my $albumYear = $prefs->get('showYearWithAlbum') ? $album->{year} || (localtime($album->{released_at}))[5] + 1900 || 0 : 0;

	if ( $album->{hires_streamable} && $albumname !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($album) eq 'flac' ) {
		$albumname .= ' ' . cstring($client, 'PLUGIN_QOBUZ_HIRES');
	}

	my $item = { image => ref $album->{image} ? $album->{image}->{large} : $album->{image} };

	my $sortFavsAlphabetically = $prefs->get('sortFavsAlphabetically') || 0;
	if ($sortFavsAlphabetically == 1) {
		$item->{name} = $albumname . ($artist ? ' - ' . $artist : '');
	}
	else {
		$item->{name} = $artist . ($artist && $albumname ? ' - ' : '') . $albumname;
	}

	if ($albumname) {
		$item->{line1} = $albumname;
		#$item->{line2} = $artist . " (" . $album->{tracks_count}. ' - ' . (ref $album->{genre} ? $album->{genre}->{name} : $album->{genre}) . ($albumYear ? ' - ' . $albumYear . ')' : ')'); #Sven 2023-10-09 track_count, genre and year added
		$item->{line2} = ( join(', ', map { $_->{name} } Plugins::Qobuz::API::Common->getMainArtists($album)) || $artist )
						. " (" . $album->{tracks_count}. ' - ' . (ref $album->{genre} ? $album->{genre}->{name} : $album->{genre}) . ($albumYear ? ' - ' . $albumYear . ')' : ')'); #Sven 2023-10-09 track_count, genre and year added
#						. ($albumYear ? ' (' . $albumYear . ')' : '');
		$item->{name} .= $albumYear ? "\n(" . $albumYear . ')' : '';
	}

	if ( $prefs->get('parentalWarning') && $album->{parental_warning} ) {
		$item->{name}  .= ' [E]';
		$item->{line1} .= ' [E]';
	}

#if ( ! _isReleased($album)  || (!$album->{streamable} && ! $prefs->get('playSamples')) ) {
#	my $sorry = ' - ' . cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE');
#	$item->{name}  .= $sorry;
#	$item->{line2} .= $sorry;
#	#$item->{type} = 'text';
#}
#else {
		if (!$album->{streamable} || !_isReleased($album) ) {
			$item->{name}  = '* ' . $item->{name};
			$item->{line2} = '* ' . $item->{line2};
		} else {
			$item->{type}  = ($prefs->get('albumViewType') eq "0") ? 'link' : 'playlist';
		}
		
		$item->{url}         = \&QobuzGetTracks;
		$item->{passthrough} = [{ album_id => $album->{id}, album_title => $album->{title} }];
#}

	return $item;
}

#Sven 2019-04-17, 2025-11-03
sub _artistItem {
	my ($client, $artist, $withIcon, $sorted) = @_;

	my $artistId = $artist->{id};

	#Sven 2022-05-11 - Erweiterung um Anzeige von Rollen, falls vorhanden
	my $roles = $artist->{roles};
		
	my $item =  {
		name => $artist->{name} . (($roles && scalar @$roles) ? ' (' . join(', ', map { $_ } @$roles) . ')' : ''),
		type => 'artist', #'link',
		url  => \&QobuzArtist,
		passthrough => [{ artistId => $artistId }],
		favorites_url  => 'qobuz://artist:' . $artistId, #fügt dem Contextmenu"In Favoriten speichern" hinzu
		favorites_type => 'artist',
	};

	$item->{image}   = $artist->{picture} || getAPIHandler($client)->getArtistPicture($artistId) if $withIcon;
	$item->{textkey} = substr( Slim::Utils::Text::ignoreCaseArticles($item->{name}), 0, 1 ) if $sorted;

	return $item;
}

#Sven 2020-03-28, 2022-05-11
sub _playlistItem {
	my ($playlist, $isWeb) = @_;

	my $args =  { 
		name  => $playlist->{name} || $playlist->{title},
		owner => $playlist->{owner}->{name},
		image => Plugins::Qobuz::API::Common->getPlaylistImage($playlist),
	};

	return {
		name  => $args->{name}, # . (($isWeb && $owner) ? " - $owner" : ''),
		line2 => join(' - ', ($args->{owner}, $playlist->{tracks_count},  _sec2hms($playlist->{duration}))),
		url   => \&QobuzPlaylistItem,
		image => $args->{image},
		type  => 'link',
		passthrough => [ $playlist, $args ],
	};
}

##Sven 2025-11-03
sub _countDuration {
	my ($client, $count, $duration) = @_;

	return $count . ' ' . cstring($client, ($count eq 1) ? 'PLUGIN_QOBUZ_TRACK' : 'PLUGIN_QOBUZ_TRACKS' ) . ' - ' . cstring($client, 'LENGTH') . ' ' . _sec2hms($duration);
}

#Sven 2023-10-08, 2025-09-22 $isWeb currently has no effect, not even in the original version of v3.6.2.
sub _trackItem {
	my ($client, $track, $isWeb) = @_;

	my $title  = Plugins::Qobuz::API::Common->addVersionToTitle($track);
	if ($track->{track_number}) { $title = sprintf('%02s. %s', $track->{track_number}, $title); } #
	my $album  = $track->{album};
	#my $artist = Plugins::Qobuz::API::Common->getArtistName($track, $album);
	my $artistNames = [ map { $_->{name} } Plugins::Qobuz::API::Common->getMainArtists($album) ];
	Plugins::Qobuz::API::Common->removeArtistsIfNotOnTrack($track, $artistNames);
	if ($track->{performer} && Plugins::Qobuz::API::Common->trackPerformerIsMainArtist($track) ) {
		push @$artistNames, $track->{performer}->{name};
	}
	my %seen;
	my $artist = join(', ', grep { !$seen{$_}++ } @$artistNames);
	my $albumtitle  = $album->{title} || '';
	if ( $albumtitle && $prefs->get('showDiscs') ) {
		$albumtitle = Slim::Music::Info::addDiscNumberToAlbumTitle($albumtitle,$track->{media_number},$album->{media_count});
	}

		#name  => $isWeb ? sprintf('%s - %s', $title, $albumtitle) : sprintf('%02s - %s', $track->{track_number}, $title),
		#line1 => sprintf('%02s. %s', $track->{track_number}, $track->{title}), 
		#line2 => sprintf('%s - %s - %s', _sec2hms($track->{duration}), $artist, _quality($track)),
		#line2 => _sec2hms($track->{duration}) . ' - ' . $artist . ($artist && $albumtitle ? ' - ' : '') . $albumtitle,

	my $item = {
		name  => sprintf('%s %s %s %s %s', $title, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $albumtitle),
		line1 => $title,
		line2 => $artist . ($artist && $albumtitle ? ' - ' : '') . $albumtitle . ' - ' . _sec2hms($track->{duration}), #Sven
		line2 => join( ' - ', ($artist, $albumtitle, _sec2hms($track->{duration})) ), #Sven
		image => Plugins::Qobuz::API::Common->getImageFromImagesHash($album->{image}),
	};

	if ( $track->{hires_streamable} && $item->{name} !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($album) eq 'flac' ) {
		$item->{name}  .= ' ' . cstring($client, 'PLUGIN_QOBUZ_HIRES');
		$item->{line1} .= ' ' . cstring($client, 'PLUGIN_QOBUZ_HIRES');
	}

	# Enhancements to work/composer display for classical music (tags returned from Qobuz are all over the place)
	if ( isClassique($track->{album}) && $prefs->get('useClassicalEnhancements') ) {
		if ( $track->{work} ) {
			$item->{work} = $track->{work};
		} else {
			# Try to set work to the title, but without composer if it's in there
			if ( $track->{composer}->{name} && $track->{title} ) {
				my @titleSplit = split /:\s*/, $track->{title};
				$item->{work} = $track->{title};
				if ( index($track->{composer}->{name}, $titleSplit[0]) != -1 ) {
					$item->{work} =~ s/\Q$titleSplit[0]\E:\s*//;
				}
			}
			# try to remove the title (ie track, movement) from the work
			my @titleSplit = split /:\s*/, $track->{title};
			my $tempTitle = @titleSplit[-1];
			$item->{work} =~ s/:\s*\Q$tempTitle\E//;
			$item->{line1} =~ s/\Q$item->{work}\E://;
		}
		$item->{displayWork} = $item->{work};
		if ( $track->{composer}->{name} ) {
			$item->{displayWork} = $track->{composer}->{name} . string('COLON') . ' ' . $item->{work};
			my $composerSurname = (split ' ', $track->{composer}->{name})[-1];
			$item->{line1} =~ s/\Q$composerSurname\E://;
		}
		$item->{line2} .= " - " . $item->{work} if $item->{work};
	}

	if ( $album ) {
		$item->{year} = $album->{year} || substr($album->{release_date_stream},0,4) || 0;
	}

	if ( $prefs->get('parentalWarning') && $track->{parental_warning} ) {
		$item->{name} .= ' [E]';
		$item->{line1} .= ' [E]';
	}

	if ($album && $album->{released_at} && $album->{released_at} > time) {
	#if ($track->{released_at} && $track->{released_at} > time) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED'),
			type => 'textarea'
		}];
	}
	elsif (!$track->{streamable} && (!$prefs->get('playSamples') || !$track->{sampleable})) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
			type => 'textarea'
		}];
		$item->{name}  = '* ' . $item->{name};
		$item->{line1} = '* ' . $item->{line1};
	}
	else {
		$item->{name}      = $item->{name} . ' *' if ! $track->{streamable};
		$item->{line1}     = '* ' . $item->{line1} if !$track->{streamable};
		#$item->{line2}     = $item->{line2} . ' *' if !$track->{streamable};
		$item->{play}      = Plugins::Qobuz::API::Common->getUrl($client, $track);
		$item->{on_select} = 'play';
		$item->{playall}   = 1;
	}

	# $item->{url} = $item->{play} if $item->{play}; #Wurde am 26.10.2024 von Michael Herger hinzugefügt, wegen Material-Skin?
	# Diese Änderung hatte mein Track-Menü verschwinden lassen.
	if ($item->{play}) { #Sven 2025-09-22 jetzt wird das Track-Menü erst erzeugt und angezeigt, wenn auf den Track geklickt wird und der Menüpunkt 'Mehr...' gewählt wird.
		$item->{url} = \&QobuzTrackMenu;
		$item->{passthrough} = [{ album => $album, title => $item->{name}, artist => $artist, track => $track }];
	};
	$item->{tracknum}     = $track->{track_number};
	$item->{media_number} = $track->{media_number};
	$item->{media_count}  = $album->{media_count};

	#$log->error(Data::Dump::dump($item));
	return $item;
}

#Sven 2025-09-22 Is the contextmenu more... of a track
sub QobuzTrackMenu {
	my ($client, $cb, $params, $args) = @_;
	
	my $album = $args->{album};
	my $track = $args->{track};

	my $items = [];

	#push @$items, _albumItem($client, $album);

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'),
		items => [{name => _trackCredits($client, $track), type => 'textarea'}],
	};

	# Add a consolidated list of all artists on the album
	my $performers = {};
	_addPerformers($client, $track, $performers);
	$items = _albumPerformers($client, $performers, 1, $items);
	
	#Sven 2025-10-23
	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_RADIO'),
		type => 'menu', #'link',
		url  => \&QobuzRadio,
		passthrough => [{ track_id => $track->{id} }]
	};

	push @$items, {
		name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
		url  => \&QobuzManageFavorites,
		passthrough => [{
			trackId => $track->{id}, title => $args->{title},
			albumId => $album->{id}, album => $album->{title},
			artist => $args->{artist},
		}],
	};

	$cb->( { items => $items } );
}

#Sven the context menu of a track, creates the 'On Qobuz' menu item in the more menu
sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title}  : $track->title;
	my $label  = $track->remote ? $remoteMeta->{label} : undef;
	my $labelId = $track->remote ? $remoteMeta->{labelId} : undef;
	my $composer  = $track->remote ? [$remoteMeta->{composer}] : undef;
	my $work = $composer && $remoteMeta->{work} ? ["$remoteMeta->{composer} $remoteMeta->{work}"] : undef;
	
	$artist = (split /,/, $artist)[0]; #Sven 2022-05-03 somtimes a list of artists are received

	my $items = [];

	my ($trackId) = Plugins::Qobuz::ProtocolHandler->crackUrl($url); #Sven 2025-09-27 fix $trackId is defined only with Qobuz url
	if ( defined $trackId) {
		my $albumId = $remoteMeta ? $remoteMeta->{albumId} : undef;
		my $artistId= $remoteMeta ? $remoteMeta->{artistId} : undef;

		if ($trackId || $albumId || $artistId) {
			my $args = {};
			if ($artistId && $artist) {
				$args->{artistId} = $artistId;
				$args->{artist}   = $artist;
			}

			if ($trackId && $title) {
				$args->{trackId} = $trackId;
				$args->{title}   = $title;
			}

			if ($albumId && $album) {
				$args->{albumId} = $albumId;
				$args->{album}   = $album;
			}

			push @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
				url  => \&QobuzManageFavorites,
				passthrough => [$args],
			} if keys %$args
		}

		if (my $item = trackInfoMenuCredits($client, undef, undef, $remoteMeta)) {
			push @$items, $item;
		}
		
#		#Sven 2025-10-23 - Funktioniert beim ersten Aufruf der gecached wird noch nicht.
#       Beim zweiten mal und solange die Liste noch im Cache ist funktioert es. Crasy!
#		push @$items, {
#			name => cstring($client, 'PLUGIN_QOBUZ_RADIO'),
#			type => 'menu', #'link',
#			url  => \&QobuzRadio,
#			passthrough => [{ track_id => $trackId }]
#		};

		push @$items, {
			name  => cstring($client, 'PLUGIN_QOBUZ_RADIO'),
			type => 'link', #'menu'
			url   => sub { 
						my ($client, $cb, $params, $args) = @_;
						Slim::Control::Request::executeRequest($client, ['qobuz', 'command', ['radio', $cb, $params, $args]]);
					 },
			passthrough => [{ track_id => $trackId }],		 
		};

		# Add a consolidated list of all artists on the track
		my $performers = {};
		_addPerformers($client, $remoteMeta, $performers);
		$items = _albumPerformers($client, $performers, 1, $items);

		if (my $item = trackInfoMenuBooklet($client, undef, undef, $remoteMeta)) {
			push @$items, $item
		}
	}

	return _objInfoHandler( $client, $artist, $album, $title, $items, $label, $labelId, $composer, $work );
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta, $tags, $filter) = @_;

	return _objInfoHandler( $client, $artist->name );
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta, $tags, $filter) = @_;

	my $albumTitle = $album->title;
	my @artists;
	push @artists, $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST');

	my $label;
	my $labelId;
	my $composers;
	my $works;
	my $items = [];

	if ( !%$remoteMeta && $url =~ /^qobuz:/ ) {
		my $albumId = (split /:/, $url)[-1];

		my $qobuzAlbum = $cache->get('album_with_tracks_' . $albumId);
		getAPIHandler($client)->getAlbum(sub {
			$qobuzAlbum = shift;

			if (!$qobuzAlbum) {
				$log->error("Get album ($albumId) failed");
				return;
			}
			elsif ( $qobuzAlbum->{release_date_stream} && $qobuzAlbum->{release_date_stream} lt Slim::Utils::DateTime::shortDateF(time, "%Y-%m-%d") ) {
				$cache->set('album_with_tracks_' . $albumId, $qobuzAlbum, QOBUZ_DEFAULT_EXPIRY);
			}
		}, $albumId) unless $qobuzAlbum && ref $qobuzAlbum;

		if ( $qobuzAlbum && ref $qobuzAlbum ) {
			my %seen;
			my $performers = {};
			my $albumcredits;
			foreach my $track (@{$qobuzAlbum->{tracks}->{items}}) {
				_addPerformers($client, $track, $performers);
				$albumcredits .= _trackCredits($client, $track) . "\n\n";
				my $composer = $track->{'composer'}->{'name'};
				my $work = $track->{'work'};
				if ( $track->{'album'}->{'label'} && !$seen{$track->{'label'}} ) {
					$seen{$track->{'album'}->{'label'}} = 1;
					$label = $track->{'album'}->{'label'};
					$labelId = $track->{'album'}->{'labelId'};
				}
				if ( $composer && !$seen{$composer} ) {
					$seen{$composer} = 1;
					push @$composers, $composer;
				}
				if ( $composer && $work && !$seen{"$work $composer"} ) {
					$seen{"$work $composer"} = 1;
					push @$works, "$composer $work";
				}
			}

			my $args = {};
			$args->{albumId} = $qobuzAlbum->{id};
			$args->{album} = $qobuzAlbum->{title};
			$args->{artistId} = $qobuzAlbum->{artist}->{id};
			$args->{artist} = $qobuzAlbum->{artist}->{name};
			push @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
				url  => \&QobuzManageFavorites,
				passthrough => [$args],
			} if keys %$args;

			if ($albumcredits) {
				$albumcredits = $qobuzAlbum->{title} . "\n\n" . $albumcredits;
				push @$items, { name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'), items => [{ name => $albumcredits, type => 'textarea' }] };
			}

			$items = _albumPerformers($client, $performers, $qobuzAlbum->{tracks_count}, $items);

			if ($qobuzAlbum->{description}) {
				push @$items, {
					name  => cstring($client, 'DESCRIPTION'),
					items => [{
						name => _stripHTML($qobuzAlbum->{description}),
						type => 'textarea',
					}],
				};
			};

			if (my $item = trackInfoMenuBooklet($client, undef, undef, $qobuzAlbum)) {
				push @$items, $item
			}
		}
	}

	return _objInfoHandler( $client, $artists[0]->name, $albumTitle, undef, $items, $label, $labelId, $composers, $works);
}

sub _objInfoHandler {
	my ( $client, $artist, $album, $track, $items, $label, $labelId, $composer, $work ) = @_;

	#Sven 2025-09-28 fix for context menu of a radio playlist item, no 'on Qobuz' if album or artist is not present.
	$track = undef unless ($artist || $album); 

	$items ||= [];

	push @$items, {
		name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $label,
		url   => \&QobuzLabelInfo,
		passthrough => [ $labelId ],
	} if $label && $labelId;

	#Sven 2025-09-28 QobuzSearch with type (albums, artists, tracks, ...), optimized code which is independent from unknown names.
	my $sItems = [ 
		{ type => 'artists', value => $artist, caption => 'ARTIST' },
		{ type => 'albums',  value => $album,  caption => 'ALBUM' },
		{ type => 'tracks',  value => $track,  caption => 'TRACK' },
	];
	foreach (@$composer) { #Sven 2025-10-24
		push @$sItems, { type => 'artists',  value => $_,  caption => 'COMPOSER' } unless ($_ eq $artist);
	}	
	push @$sItems, { type => 'works',    value => $_,  caption => 'PLUGIN_QOBUZ_WORK' } foreach @$work;

	foreach (@$sItems) {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SEARCH', cstring($client, $_->{caption}), $_->{value}),
			url  => \&QobuzSearch,
			passthrough => [{
				q => $_->{value},
				type => $_->{type}, #Sven 2025-09-28
			}]
		} if $_->{value};
	}

	my $menu;
	if ( scalar @$items == 1) {
		$menu = $items->[0];
		$menu->{name} = cstring($client, 'PLUGIN_ON_QOBUZ');
	}
	elsif (scalar @$items) {
		$menu = {
			name  => cstring($client, 'PLUGIN_ON_QOBUZ'),
			items => $items
		};
	}

	return $menu if $menu;
}

#Sven - my version
sub trackInfoMenuCredits {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	if ( $remoteMeta && $remoteMeta->{performers} ) {
		return { name => cstring($client, 'PLUGIN_QOBUZ_CREDITS'), items => [{name => _trackCredits($client, $remoteMeta), type => 'textarea'}] };
	}
}

my $MAIN_ARTIST_RE = qr/MainArtist|\bPerformer\b|ComposerLyricist/i;
my $ARTIST_RE = qr/Performer|Keyboards|Synthesizer|Vocal|Guitar|Lyricist|Composer|Bass|Drums|Percussion||Violin|Viola|Cello|Trumpet|Conductor|Trombone|Trumpet|Horn|Tuba|Flute|Euphonium|Piano|Orchestra|Clarinet|Didgeridoo|Cymbals|Strings|Harp/i;
my $STUDIO_RE = qr/StudioPersonnel|Other|Producer|Engineer|Prod/i;

sub trackInfoMenuPerformers {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	#if ( $remoteMeta && (my $performers = $remoteMeta->{performers}) ) {
	if ( $remoteMeta && $remoteMeta->{performers} ) {
		my @performers = map {
			s/,?\s?(MainArtist|AssociatedPerformer|StudioPersonnel|ComposerLyricist)//ig;
			s/,/:/;
			{
				name => $_,
				url  => \&QobuzSearch,
				passthrough => [{
					q => (split /:/, $_)[0],
				}]
			}
		} sort {
			return $a cmp $b if $a =~ $MAIN_ARTIST_RE && $b =~ $MAIN_ARTIST_RE;
			return -1 if $a =~ $MAIN_ARTIST_RE;
			return 1 if $b =~ $MAIN_ARTIST_RE;

			return $a cmp $b if $a =~ $ARTIST_RE && $b =~ $ARTIST_RE;
			return -1 if $a =~ $ARTIST_RE;
			return 1 if $b =~ $ARTIST_RE;

			return $a cmp $b if $a =~ $STUDIO_RE && $b =~ $STUDIO_RE;
			return -1 if $a =~ $STUDIO_RE;
			return 1 if $b =~ $STUDIO_RE;

			return $a cmp $b;
		} split(/ - /, $remoteMeta->{performers});

		return {
			name => cstring($client, 'PLUGIN_QOBUZ_PERFORMERS'),
			items => \@performers,
		};
	}

	return {};
}

sub trackInfoMenuBooklet {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $item;

	eval {
		my $goodies = $remoteMeta->{goodies};
		if ($goodies && ref $goodies && scalar @$goodies) {

			# Browser client (eg Material)
			if ( Slim::Utils::Versions->compareVersions($::VERSION, '8.4.0') >= 0 && _isBrowser($client)
				# or null client (eg Default skin)
				|| !$client->controllerUA )
			{
				if (scalar @$goodies == 1 && lc(@$goodies[0]->{name}) eq "livret num\xe9rique") {
					$item = {
						name => _localizeGoodies($client, @$goodies[0]->{name}),
						weblink => @$goodies[0]->{url},
					};
				} else {
					my $items = [];
					foreach ( @$goodies ) {
						if ($_->{url} =~ $GOODIE_URL_PARSER_RE) {
							push @$items, {
								name => _localizeGoodies($client, $_->{name}),
								weblink => $_->{url},
							};
						}
					}
					if (scalar @$items) {
						$item = {
							name => cstring($client, 'PLUGIN_QOBUZ_GOODIES'),
							items => $items
						};
					}
				}

			# jive clients like iPeng etc. can display web content, but need special handling...
			} elsif ( _canWeblink($client) )  {
				$item = {
					name => cstring($client, 'PLUGIN_QOBUZ_GOODIES'),
					itemActions => {
						items => {
							command  => [ 'qobuz', 'goodies' ],
							fixedParams => {
								goodies => to_json($goodies),
							}
						},
					},
				};
			}
		}
	};

	return $item;
}

sub _localizeGoodies {
	my ($client, $name) = @_;

	if ( my $localizedToken = $localizationTable{$name} ) {
		$name = cstring($client, $localizedToken);
	}

	return $name;
}

sub _getGoodiesCLI {
	my $request = shift;

	my $client = $request->client;

	if ($request->isNotQuery([['qobuz'], ['goodies']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->setStatusProcessing();

	my $goodies = [ eval { grep {
		$_->{url} =~ $GOODIE_URL_PARSER_RE;
	} @{from_json($request->getParam('goodies'))} } ] || '[]';

	my $i = 0;

	if (!scalar @$goodies) {
		$request->addResult('window', {
			textArea => cstring($client, 'EMPTY'),
		});
		$i++;
	}
	else {
		foreach (@$goodies) {
			$request->addResultLoop('item_loop', $i, 'text', _localizeGoodies($client, $_->{name}) . ' - ' . $_->{description}); #Sven 2022-05-01 add decription
			$request->addResultLoop('item_loop', $i, 'weblink', $_->{url});
			$i++;
		}
	}

	$request->addResult('count', $i);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}

#Sven 2025-10-25 - New cli command to get show an album or an radio
sub cliQobuzCommand {
	my $request = shift;
	
	# check this is the correct query.
	if ($request->isNotCommand([['qobuz'], ['command']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client  = $request->client();
	my ($command, $cb, $params, $args) = @{$request->getParam('_aParams')};

	my $func = ($command eq 'album') ? \&QobuzGetTracks : \&QobuzRadio;

	$func->($client, $cb, $params, $args); 
	
	$request->setStatusDone();
}

#Sven - ab hier ist der Kode bisher identisch mit der Version von Michael Herger
sub cliQobuzPlayAlbum {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotCommand([['qobuz'], ['playalbum', 'addalbum']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $albumId = $request->getParam('_p2');

	getAPIHandler($client)->getAlbum(sub {
		my $album = shift;

		if (!$album) {
			$log->error("Get album ($albumId) failed");
			return;
		}

		my $tracks = [];

		foreach my $track (@{$album->{tracks}->{items}}) {
			push @$tracks, Plugins::Qobuz::API::Common->getUrl($client, $track);
		}

		my $action = $request->isCommand([['qobuz'], ['addalbum']]) ? 'addtracks' : 'playtracks';

		$client->execute( ["playlist", $action, "listref", $tracks] );
	}, $albumId);

	$request->setStatusDone();
}

sub _canWeblink {
	my ($client) = @_;
	return $client && $client->controllerUA && ($client->controllerUA =~ $WEBLINK_SUPPORTED_UA_RE || $client->controllerUA =~ $WEBBROWSER_UA_RE);
}

sub _isBrowser {
	my ($client) = @_;
	return ( $client && $client->controllerUA && $client->controllerUA =~ $WEBBROWSER_UA_RE );
}

sub _stripHTML {
	my $html = shift;
	$html =~ s/<(?:[^>'”]*|([‘”]).*?\1)*>//ig;
	return $html;
}

sub _imgProxy { if (CAN_IMAGEPROXY) {
	my ($url, $spec) = @_;

	#main::DEBUGLOG && $log->debug("Artwork for $url, $spec");

	# https://github.com/Qobuz/api-documentation#album-cover-sizes
	my $size = Slim::Web::ImageProxy->getRightSize($spec, {
		50 => 50,
		160 => 160,
		300 => 300,
		600 => 600
	}) || 'max';

	$url =~ s/(\d{13}_)[\dmax]+(\.jpg)/$1$size$2/ if $size;

	#main::DEBUGLOG && $log->debug("Artwork file url is '$url'");

	return $url;
} }

sub _isReleased {  # determine if the referenced album has been released
	my ($album) = @_;
	my $ltime = time;
	# only check date field if the release date is within +/- 14 hours of now
	if ($ltime > ($album->{released_at} + 50400)) {
		return 1;
	} elsif ($ltime < ($album->{released_at} - 50400)) {
		return 0;
	} else {  # check the local date
		my $ldate = Slim::Utils::DateTime::shortDateF($ltime, "%Y-%m-%d");
		return ($ldate ge $album->{release_date_stream});
	}
}

sub _isMainArtist {  # determine if an artist is a main artist on the release
	my ($artistId, $album) = @_;

	if ($album->{artist} && $album->{artist}->{id} == $artistId) {
		return 1;
	} elsif (ref $album->{artists} && scalar @{$album->{artists}} ) {  # check the other artists
		for my $artists ( @{$album->{artists}} ) {
			if ($artists->{id} == $artistId && grep(/main-artist/, @{$artists->{roles}})) {
				return 1;
			}
		}
	}
	return 0;
}

sub _isMainArtistByName {  # determine if an artist is a main artist on the release
	my ($artistName, $album) = @_;

	$artistName = lc($artistName);
	if ($album->{artist} && lc($album->{artist}->{name}) eq $artistName) {
		return 1;
	} elsif (ref $album->{artists} && scalar @{$album->{artists}} ) {  # check the other artists
		for my $artists ( @{$album->{artists}} ) {
			if (lc($artists->{name}) eq $artistName && grep(/main-artist/, @{$artists->{roles}})) {
				return 1;
			}
		}
	}
	return 0;
}

sub _localDate {  # convert input date string in format YYYY-MM-DD to localized short date format
	my $iDate = shift;
	my @dt = split(/-/, $iDate);
	return strftime(preferences('server')->get('shortdateFormat'), 0, 0, 0, $dt[2], $dt[1] - 1, $dt[0] - 1900);
}

# TODO - make search per account
sub addRecentSearch {
	my $search = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++addRecentSearch");

	my $list = $prefs->get('qobuz_recent_search') || [];

	$list = [ grep { $_ ne $search } @$list ];

	push @$list, $search;

	shift(@$list) while scalar @$list > MAX_RECENT;

	$prefs->set( 'qobuz_recent_search', $list );
	main::DEBUGLOG && $log->is_debug && $log->debug("--addRecentSearch");
	return;
}

sub _recentSearchesCLI {
	my $request = shift;
	my $client = $request->client;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_recentSearchesCLI");

	# check this is the correct command.
	if ($request->isNotCommand([['qobuz'], ['recentsearches']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $list = $prefs->get('qobuz_recent_search') || [];
	my $del = $request->getParam('deleteMenu') || $request->getParam('delete') || 0;

	if (!scalar @$list || $del >= scalar @$list) {
		$log->error('Search item to delete is outside the history list!');
		$request->setStatusBadParams();
		return;
	}

	my $items = [];

	if (defined $request->getParam('deleteMenu')) {
		push @$items,
		{
			text => cstring($client, 'DELETE') . cstring($client, 'COLON') . ' "' . ($list->[$del] || '') . '"',
			actions => {
				go => {
					player => 0,
					cmd    => ['qobuz', 'recentsearches' ],
					params => {
						delete => $del
					},
				},
			},
			nextWindow => 'parent',
		},
		{
			text => cstring($client, 'PLUGIN_QOBUZ_CLEAR_SEARCH_HISTORY'),
			actions => {
				go => {
					player => 0,
					cmd    => ['qobuz', 'recentsearches' ],
					params => {
						deleteAll => 1
					},
				}
			},
			nextWindow => 'grandParent',
		};

		$request->addResult('offset', 0);
		$request->addResult('count', scalar @$items);
		$request->addResult('item_loop', $items);
	} elsif ($request->getParam('deleteAll')) {
		$prefs->set( 'qobuz_recent_search', [] );
	} elsif (defined $request->getParam('delete')) {
		splice(@$list, $del, 1);
		$prefs->set( 'qobuz_recent_search', $list );
	}

	$request->setStatusDone;
	main::DEBUGLOG && $log->is_debug && $log->debug("--_recentSearchesCLI");
	return;
}

sub getAPIHandler {
	my ($clientOrId) = @_;

	my $api;

	if (ref $clientOrId) {
		# $clientOrId is a Player::Client object
		$api = $clientOrId->pluginData('api');
		
		if ( !$api ) {
			my $userdata = Plugins::Qobuz::API::Common->getAccountData($clientOrId);
			# if there's no account assigned to the player, just pick one
			if (!$userdata) {
				my $userId = Plugins::Qobuz::API::Common->getSomeUserId($clientOrId); 
				$prefs->client($clientOrId)->set('userId', $userId) if $userId;
			}
			$api = $clientOrId->pluginData( api => Plugins::Qobuz::API->new({ client => $clientOrId }) );
		}
	}
	else {
		# $clientOrId is a Qobuz user-ID
		$clientOrId ||= Plugins::Qobuz::API::Common->getSomeUserId($clientOrId);
		$api = Plugins::Qobuz::API->new({
			userId => $clientOrId
		});
	}

	logBacktrace("Failed to get a Qobuz API instance: $clientOrId") unless $api;

	return $api;
}

1;
