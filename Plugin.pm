package Plugins::Qobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Tie::RegexpHash;
use POSIX qw(strftime);

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
	groupReleases => 0,
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

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.qobuz',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_QOBUZ',
	logGroups    => 'SCANNER',
} );

use constant PLUGIN_TAG => 'qobuz';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

my $cache = Plugins::Qobuz::API::Common->getCache();

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
	Slim::Menu::TrackInfo->registerInfoProvider( qobuzTrackInfo => (
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( qobuzArtistInfo => (
		func => \&artistInfoMenu
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( qobuzAlbumInfo => (
		func => \&albumInfoMenu
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( qobuzSearch => (
		func => \&searchMenu
	) );

#                                                             |requires Client
#                                                             |  |is a Query
#                                                             |  |  |has Tags
#                                                             |  |  |  |Function to call
#                                                             C  Q  T  F
	Slim::Control::Request::addDispatch(['qobuz', 'goodies'], [1, 1, 1, \&_getGoodiesCLI]);

	Slim::Control::Request::addDispatch(['qobuz', 'playalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	Slim::Control::Request::addDispatch(['qobuz', 'addalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	Slim::Control::Request::addDispatch(['qobuz','recentsearches'],[1, 0, 1, \&_recentSearchesCLI]);

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

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if ( !Plugins::Qobuz::API::Common->hasAccount() ) {
		return $cb->({
			items => [{
				name => cstring($client, 'PLUGIN_QOBUZ_REQUIRES_CREDENTIALS'),
				type => 'textarea',
			}]
		});
	}

	my $params = $args->{params};

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
					url  => sub {
						my ($client, $cb, $params) = @_;
						my $menu = searchMenu($client, {
							search => lc($recent)
						});
						$cb->({
							items => $menu->{items}
						});
					},
					itemActions => {
						info => {
							command     => ['qobuz', 'recentsearches'],
							fixedParams => { deleteMenu => $i++ },
						},
					},
					passthrough => [ { type => 'search' } ],
				};
			}

			unshift @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NEW_SEARCH'),
				type  => 'search',
				url  => sub {
					my ($client, $cb, $params) = @_;
					addRecentSearch($params->{search});
					my $menu = searchMenu($client, {
						search => lc($params->{search})
					});
					$cb->({
						items => $menu->{items}
					});
				},
				passthrough => [ { type => 'search' } ],
			};

			$cb->({ items => $items });
		},
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_USERPURCHASES'),
		url  => \&QobuzUserPurchases,
		image => 'html/images/albums.png'
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_USER_FAVORITES'),
		url  => \&QobuzUserFavorites,
		image => 'html/images/favorites.png'
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_USERPLAYLISTS'),
		url  => \&QobuzUserPlaylists,
		image => 'html/images/playlists.png'
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS'),
		url  => \&QobuzPublicPlaylists,
		image => 'html/images/playlists.png',
		passthrough => [{
			type    => 'editor-picks',
		}]
	},{
	# 	name => cstring($client, 'PLUGIN_QOBUZ_LATESTPLAYLISTS'),
	# 	url  => \&QobuzPublicPlaylists,
	# 	image => 'html/images/playlists.png',
	# 	passthrough => [{
	# 		type    => 'last-created',
	# 	}]
	# },{
		name => cstring($client, 'PLUGIN_QOBUZ_BESTSELLERS'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			type    => 'best-sellers',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_NEW_RELEASES'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			type    => 'new-releases-full',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_PRESS'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			type    => 'press-awards',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_EDITOR_PICKS'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			type    => 'editor-picks',
		}]
	},{
		name  => cstring($client, 'GENRES'),
		image => 'html/images/genres.png',
		type => 'link',
		url  => \&QobuzGenres
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_MYWEEKLYQ'),
		type  => 'playlist',
		url  => \&QobuzMyWeeklyQ,
		image => 'html/images/playlists.png'
	}];

	if ($client && scalar @{ Plugins::Qobuz::API::Common::getAccountList() } > 1) {
		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SELECT_ACCOUNT'),
			image => __PACKAGE__->_pluginDataFor('icon'),
			url => \&QobuzSelectAccount,
		};
	}

	$cb->({ items => $items });
}

sub QobuzSelectAccount {
	my $cb = $_[1];

	my $items = [ map {
		{
			name => $_->[0],
			url => sub {
				my ($client, $cb2, $params, $args) = @_;

				$client->pluginData(api => 0);
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

sub QobuzMyWeeklyQ {
	my ($client, $cb, $params) = @_;

	if (Plugins::Qobuz::API::Common->getToken($client) && !Plugins::Qobuz::API::Common->getWebToken($client)) {
		return QobuzGetWebToken(@_);
	}

	getAPIHandler($client)->getMyWeekly(sub {
		my $myWeekly = shift;

		if (!$myWeekly) {
			$cb->();
			return;
		}

		my $tracks = [];

		foreach my $track ( @{$myWeekly->{tracks}->{items} || []} ) {
			push @$tracks, _trackItem($client, $track);
		}

		return $cb->({
			name  => $myWeekly->{title},
			name2 => $myWeekly->{baseline},
			items => $tracks,
		});
	});
}

sub QobuzGetWebToken {
	my ($client, $cb, $params) = @_;

	my $username = Plugins::Qobuz::API::Common->username($client);

	return $cb->({ items => [{
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
	}] });
}

sub QobuzSearch {
	my ($client, $cb, $params, $args) = @_;

	$args ||= {};
	$params->{search} ||= $args->{q};
	my $type   = lc($args->{type} || '');
	my $search = lc($params->{search});

	getAPIHandler($client)->search(sub {
		my $searchResult = shift;

		if (!$searchResult) {
			$cb->();
			return;
		}

		my $albums = [];
		for my $album ( @{$searchResult->{albums}->{items} || []} ) {
			# XXX - unfortunately the album results don't return the artist's ID
			next if $args->{artistId} && !($album->{artist} && lc($album->{artist}->{name}) eq $search);
			push @$albums, _albumItem($client, $album);
		}

		my $artists = [];
		for my $artist ( @{$searchResult->{artists}->{items} || []} ) {
			push @$artists, _artistItem($client, $artist, 1);
		}

		my $tracks = [];
		for my $track ( @{$searchResult->{tracks}->{items} || []} ) {
			next if $args->{artistId} && !($track->{performer} && $track->{performer}->{id} eq $args->{artistId});
			push @$tracks, _trackItem($client, $track, $params->{isWeb});
		}

		my $playlists = [];
		for my $playlist ( @{$searchResult->{playlists}->{items} || []} ) {
			next if defined $playlist->{tracks_count} && !$playlist->{tracks_count};
			push @$playlists, _playlistItem($playlist, 'show-owner', $params->{isWeb});
		}

		my $items = [];

		push @$items, {
			name  => cstring($client, 'ALBUMS'),
			items => $albums,
			image => 'html/images/albums.png',
		} if scalar @$albums;

		push @$items, {
			name  => cstring($client, 'ARTISTS'),
			items => $artists,
			image => 'html/images/artists.png',
		} if scalar @$artists;

		push @$items, {
			name  => cstring($client, 'SONGS'),
			items => $tracks,
			image => 'html/images/playlists.png',
		} if scalar @$tracks;

		push @$items, {
			name  => cstring($client, 'PLAYLISTS'),
			items => $playlists,
			image => 'html/images/playlists.png',
		} if scalar @$playlists;

		if (scalar @$items == 1) {
			$items = $items->[0]->{items};
		}

		$cb->( {
			items => $items
		} );
	}, $search, $type);
}

sub browseArtistMenu {
	my ($client, $cb, $params, $args) = @_;

	my $artistId = $params->{artist_id} || $args->{artist_id};
	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {
		if (my ($extId) = grep /qobuz:artist:(\d+)/, @{$artistObj->extIds}) {
			($args->{artistId}) = $extId =~ /qobuz:artist:(\d+)/;
			return QobuzArtist($client, $cb, $params, $args);
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
		type  => 'text',
		title => cstring($client, 'EMPTY'),
	}]);
}

sub QobuzArtist {
	my ($client, $cb, $params, $args) = @_;

	my $api = getAPIHandler($client);

	$api->getArtist(sub {
		my $artist = shift;

		if ($artist->{status} && $artist->{status} =~ /error/i) {
			$cb->();
			return;
		}

		my $groupByReleaseType = $prefs->get('groupReleases');

		my $items = [{
			name  => $groupByReleaseType ? cstring($client, 'PLUGIN_QOBUZ_RELEASES') : cstring($client, 'ALBUMS'),
			# placeholder URL - please see below for albums returned in the artist query
			url   => \&QobuzSearch,
			image => 'html/images/albums.png',
			passthrough => [{
				q        => $artist->{name},
				type     => 'albums',
				artistId => $artist->{id},
			}]
		},{
			name  => cstring($client, 'SONGS'),
			url   => \&QobuzSearch,
			image => 'html/images/playlists.png',
			passthrough => [{
				q        => $artist->{name},
				type     => 'tracks',
				artistId => $artist->{id},
			}]
		}];

		if ($artist->{biography}) {
			my $images = $artist->{image} || {};
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_BIOGRAPHY'),
				image => Plugins::Qobuz::API::Common->getImageFromImagesHash($images) || $api->getArtistPicture($artist->{id}) || 'html/images/artists.png',
				items => [{
					name => _stripHTML($artist->{biography}->{content}),
					type => 'textarea',
				}],
			}
		}

		# use album list if it was returned in the artist lookup
		if ($artist->{albums}) {
			my $albums = [];

			# group by release type if requested
			if ($groupByReleaseType) {
				for my $album ( @{$artist->{albums}->{items}} ) {
					if ($album->{duration} >= 1800 || $album->{tracks_count} > 6) {
						$album->{release_type} = "Album";
					} elsif ($album->{tracks_count} < 4) {
						$album->{release_type} = "Single";
					} else {
						$album->{release_type} = "Ep";
					}
				}
			}

			# sort by release date if requested
			my $sortByDate = $prefs->get('sortArtistAlbums');

			$artist->{albums}->{items} = [ sort {
				if ($sortByDate) {
					return $sortByDate == 1 ? ( $a->{release_type} cmp $b->{release_type} || $b->{released_at}*1 <=> $a->{released_at}*1 )
											: ( $a->{release_type} cmp $b->{release_type} || $a->{released_at}*1 <=> $b->{released_at}*1 );
				}
				else {
					return $a->{release_type} cmp $b->{release_type} || lc($a->{title}) cmp lc($b->{title});
				}

			} @{$artist->{albums}->{items} || []} ];

			my $lastReleaseType = "";

			for my $album ( @{$artist->{albums}->{items}} ) {
				next if $args->{artistId} && $album->{artist}->{id} != $args->{artistId};
				if ($album->{release_type} ne $lastReleaseType) {
					$lastReleaseType = $album->{release_type};
					my $relType = "";
					if ($lastReleaseType eq "Album") {
						$relType = cstring($client, 'ALBUMS');
					} elsif ($lastReleaseType eq "Ep") {
						$relType = cstring($client, 'RELEASE_TYPE_EPS');
					} elsif ($lastReleaseType eq "Single") {
						$relType = cstring($client, 'RELEASE_TYPE_SINGLES');
					} else {
						$relType = "Unknown";  #should never occur
					}

					push @$albums, {
						name => $relType,
						image => 'html/images/albums.png',
						type => 'text'
					} ;
				}
				push @$albums, _albumItem($client, $album);
			}

			if (@$albums) {
				$items->[0]->{items} = $albums;
				delete $items->[0]->{url};
			}
		}

		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SIMILAR_ARTISTS'),
			image => 'html/images/artists.png',
			url => sub {
				my ($client, $cb, $params, $args) = @_;

				$api->getSimilarArtists(sub {
					my $searchResult = shift;

					my $items = [];

					$cb->() unless $searchResult;

					for my $artist ( @{$searchResult->{artists}->{items}} ) {
						push @$items, _artistItem($client, $artist, 1);
					}

					$cb->( {
						items => $items
					} );
				}, $args->{artistId});
			},
			passthrough => [{
				artistId  => $artist->{id},
			}],
		};

		$api->getUserFavorites(sub {
			my $favorites = shift;
			my $artistId = $artist->{id};
			my $isFavorite = ($favorites && $favorites->{artists}) ? grep { $_->{id} eq $artistId } @{$favorites->{artists}->{items}} : 0;

			push @$items, {
 				name => cstring($client, $isFavorite ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $artist->{name}),
				url  => $isFavorite ? \&QobuzDeleteFavorite : \&QobuzAddFavorite,
				image => 'html/images/favorites.png',
				passthrough => [{
					artist_ids => $artist->{id},
				}],
				nextWindow => 'parent'
			};

			$cb->({
				items => $items
			});
		});
	}, $args->{artistId});
}

sub QobuzGenres {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId} || '';

	getAPIHandler($client)->getGenres(sub {
		my $genres = shift;

		if (!$genres) {
			$log->error("Get genres ($genreId) failed");
			return;
		}

		my $items = [];

		for my $genre ( @{$genres->{genres}->{items}}) {
			my $item = {};

			$item = {
				name => $genre->{name},
				url  => \&QobuzGenre,
				passthrough => [{
					genreId => $genre->{id},
				}]
			};

			push @$items, $item;
		}

		$cb->({
			items => $items
		})
	}, $genreId);
}


sub QobuzGenre {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId} || '';

	my $items = [{
		name => cstring($client, 'PLUGIN_QOBUZ_BESTSELLERS'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			genreId => $genreId,
			type    => 'best-sellers',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_NEW_RELEASES'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			genreId => $genreId,
			type    => 'new-releases-full',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_PRESS'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			genreId => $genreId,
			type    => 'press-awards',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_EDITOR_PICKS'),
		url  => \&QobuzFeaturedAlbums,
		image => 'html/images/albums.png',
		passthrough => [{
			genreId => $genreId,
			type    => 'editor-picks',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_PUBLICPLAYLISTS'),
		url  => \&QobuzPublicPlaylists,
		image => 'html/images/playlists.png',
		passthrough => [{
			genreId => $genreId,
			type    => 'editor-picks',
		}]
	},{
		name => cstring($client, 'PLUGIN_QOBUZ_LATESTPLAYLISTS'),
		url  => \&QobuzPublicPlaylists,
		image => 'html/images/playlists.png',
		passthrough => [{
			genreId => $genreId,
			type    => 'last-created',
		}]
	}];

	$cb->({
		items => $items
	});
}


sub QobuzFeaturedAlbums {
	my ($client, $cb, $params, $args) = @_;
	my $type    = $args->{type};
	my $genreId = $args->{genreId};

	getAPIHandler($client)->getFeaturedAlbums(sub {
		my $albums = shift;

		my $items = [];

		foreach my $album ( @{$albums->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({
			items => $items
		})
	}, $type, $genreId);
}

sub QobuzLabel {
	my ($client, $cb, $params, $args) = @_;
	my $labelId = $args->{labelId};

	getAPIHandler($client)->getLabel(sub {
		my $albums = shift;

		my $items = [];

		foreach my $album ( @{$albums->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({
			items => $items
		})
	}, $labelId);
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
			push @$items, _trackItem($client, $track);
		}

		$cb->( {
			items => $items
		} );
	});
}

sub QobuzUserFavorites {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserFavorites(sub {
		my $favorites = shift;

		my $items = [];

		my @artists;
		for my $artist ( sort {
			Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name})
		} @{$favorites->{artists}->{items}} ) {
			push @artists,  _artistItem($client, $artist, 'withIcon');
		}

		push @$items, {
			name => cstring($client, 'ARTISTS'),
			items => \@artists,
			image => 'html/images/artists.png',
		} if @artists;

		my @albums;
		for my $album ( @{$favorites->{albums}->{items}} ) {
			push @albums, _albumItem($client, $album);
		}

		my $sortFavsAlphabetically = $prefs->get('sortFavsAlphabetically') || 0;

		push @$items, {
			name => cstring($client, 'ALBUMS'),
			items => $sortFavsAlphabetically ? [ sort { Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name}) } @albums ] : \@albums,
			image => 'html/images/albums.png',
		} if @albums;

		my @tracks;
		for my $track ( @{$favorites->{tracks}->{items}} ) {
			push @tracks, _trackItem($client, $track);
		}

		my $sortFavSongField = $sortFavsAlphabetically == 1 ? 'name' : 'line2';

		push @$items, {
			name => cstring($client, 'SONGS'),
			items => $sortFavsAlphabetically ? [ sort { Slim::Utils::Text::ignoreCaseArticles($a->{$sortFavSongField}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{$sortFavSongField}) } @tracks ] : \@tracks,
			image => 'html/images/playlists.png',
		} if @tracks;

		$cb->( {
			items => $items
		} );
	});
}

sub QobuzManageFavorites {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserFavorites(sub {
		my $favorites = shift;

		my $items = [];

		if ( (my $artist = $args->{artist}) && (my $artistId = $args->{artistId}) ) {
			my $isFavorite = grep { $_->{id} eq $artistId } @{$favorites->{artists}->{items}};

			push @$items, {
				name => cstring($client, $isFavorite ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $artist),
				url  => $isFavorite ? \&QobuzDeleteFavorite : \&QobuzAddFavorite,
				passthrough => [{
					artist_ids => $artistId
				}],
				nextWindow => 'grandparent'
			};
		}

		if ( (my $album = $args->{album}) && (my $albumId = $args->{albumId}) ) {
			my $isFavorite = grep { $_->{id} eq $albumId } @{$favorites->{albums}->{items}};

			push @$items, {
				name => cstring($client, $isFavorite ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $album),
				url  => $isFavorite ? \&QobuzDeleteFavorite : \&QobuzAddFavorite,
				passthrough => [{
					album_ids => $albumId
				}],
				nextWindow => 'grandparent'
			};
		}

		if ( (my $title = $args->{title}) && (my $trackId = $args->{trackId}) ) {
			my $isFavorite = grep { $_->{id} eq $trackId } @{$favorites->{tracks}->{items}};

			push @$items, {
				name => cstring($client, $isFavorite ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $title),
				url  => $isFavorite ? \&QobuzDeleteFavorite : \&QobuzAddFavorite,
				passthrough => [{
					track_ids => $trackId
				}],
				nextWindow => 'grandparent'
			};
		}

		$cb->( {
			items => $items
		} );
	}, 'refresh');
}

sub QobuzAddFavorite {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->createFavorite(sub {
		my $result = shift;
		$cb->({ items => [{
			name        => cstring($client, 'PLUGIN_QOBUZ_MUSIC_ADDED'),
			showBriefly => 1,
			nextWindow  => 'grandparent',
		}] });
	}, $args);
}

sub QobuzDeleteFavorite {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->deleteFavorite(sub {
		my $result = shift;
		$cb->({
			text        => $result->{status},
			showBriefly => 1,
			nextWindow  => 'grandparent',
		});
	}, $args);
}

sub QobuzUserPlaylists {
	my ($client, $cb, $params, $args) = @_;

	getAPIHandler($client)->getUserPlaylists(sub {
		_playlistCallback(shift, $cb, undef, $params->{isWeb});
	});
}

sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId};
	my $tags    = $args->{tags};
	my $type    = $args->{type} || 'editor-picks';
	my $api     = getAPIHandler($client);

	if ($type eq 'editor-picks' && !$genreId && !$tags) {
		$api->getTags(sub {
			my $tags = shift;

			if ($tags && ref $tags) {
				my $lang = lc(preferences('server')->get('language'));

				my @items = map {
					{
						name => $_->{name}->{$lang} || $_->{name}->{en},
						url  => \&QobuzPublicPlaylists,
						passthrough => [{
							tags => $_->{id},
							type => $type
						}]
					};
				} @$tags;

				$cb->( {
					items => \@items
				} );
			}
			else {
				$api->getPublicPlaylists(sub {
					_playlistCallback(shift, $cb, 'showOwner', $params->{isWeb});
				}, $type);
			}
		});
	}
	else {
		$api->getPublicPlaylists(sub {
			_playlistCallback(shift, $cb, 'showOwner', $params->{isWeb});
		}, $type, $genreId, $tags);
	}
}

sub _playlistCallback {
	my ($searchResult, $cb, $showOwner, $isWeb) = @_;

	my $playlists = [];

	for my $playlist ( @{$searchResult->{playlists}->{items}} ) {
		next if defined $playlist->{tracks_count} && !$playlist->{tracks_count};
		push @$playlists, _playlistItem($playlist, $showOwner, $isWeb);
	}

	$cb->( {
		items => $playlists
	} );
}

# sub infoSamplerate {
# 	my ( $client, $url, $track, $remoteMeta ) = @_;

# 	if ( my $sampleRate = $remoteMeta->{samplerate} ) {
# 		return {
# 			type  => 'text',
# 			label => 'SAMPLERATE',
# 			name  => sprintf('%.1f kHz', $sampleRate)
# 		};
# 	}
# }

# sub infoBitsperSample {
# 	my ( $client, $url, $track, $remoteMeta ) = @_;

# 	if ( my $samplesize = $remoteMeta->{samplesize} ) {
# 		return {
# 			type  => 'text',
# 			label => 'SAMPLESIZE',
# 			name  => $samplesize . ' ' . cstring($client, 'BITS'),
# 		};
# 	}
# }

sub QobuzGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $albumId = $args->{album_id};
	my $albumTitle = $args->{album_title};

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
					type  => 'text'
				};

				if ($isFavorite) {  # if it's an orphaned favorite, let the user delete it
					push @$items, {
						name => cstring($client, 'PLUGIN_QOBUZ_REMOVE_FAVORITE', $albumTitle),
						url  => \&QobuzDeleteFavorite,
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
			});
			return;

		} elsif (!$album->{streamable} && !$prefs->get('playSamples')) {  # the album is not streamable
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
				type  => 'text'
			};

			$cb->({
				items => $items,
			}, @_ );
			return;
		}

		if (!_isReleased($album) ) {
			my $rDate = _localDate($album->{release_date_stream});
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED') . ' (' . $rDate . ')',
				type  => 'text'
			};
		}

		my $totalDuration = 0;
		my $trackNumber = 0;
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
		my $performers= {};

		foreach my $track (@{$album->{tracks}->{items}}) {

			if (my $trackPerformers = trackInfoMenuPerformers($client, undef, undef, $track)) {
				my $performerItems = $trackPerformers->{items};
				foreach my $item (@$performerItems) {
					$item->{'track'} = $track->{'track_number'};
					$item->{'disc'} = $track->{'media_number'}||1;
				}
				push @{$performers->{$track->{'media_number'}}}, @$performerItems;
			}

			$totalDuration += $track->{duration};
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
					$workHeadingPos = push @$items,{
						name  => $formattedTrack->{displayWork},
						type  => 'text'
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
						@$items[$workHeadingPos-1]->{name} = $formattedTrack->{displayWork};
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
				push @$items,{
					name  => "--------",
					type  => 'text'
				};

				$lastwork = "";
				$noComposer = 0;
			}

			$trackNumber++;
			$lastWorksWorkId = $worksWorkId;

			push @$items, $formattedTrack;

		}

		# create a playlist for each "disc" in a multi-disc set except if we've got works (mixing disc & work playlists would go horribly wrong or at least be confusing!)
		if ( $prefs->get('showDiscs') && scalar keys %$discs && !(scalar keys %$works) && _isReleased($album) ) {
			foreach my $disc (sort { $discs->{$b}->{index} <=> $discs->{$a}->{index} } keys %$discs) {
				my $discTracks = $discs->{$disc}->{tracks};

				# insert disc item before the first of its tracks
				splice @$items, $discs->{$disc}->{index}, 0, {
					name => $discs->{$disc}->{title},
					image => $discs->{$disc}->{image},
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
									splice @$items, $idx, 0, {
										name => $workComposer->{$work}->{displayWork},
										image => 'html/images/playlists.png',
									};
								} else {
									splice @$items, $idx, 0, {
										name => $workComposer->{$work}->{displayWork},
										type => 'text',
									}
								}
							} else {
								splice @$items, $idx, 0, {
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
					unshift @$items, @workPlaylists;
				} elsif ( $workPlaylistPos eq "after" ) {
					push @$items, @workPlaylists;
				}
			}
		}

		if (my $artistItem = _artistItem($client, $album->{artist}, 1)) {
			$artistItem->{label} = 'ARTIST';
			push @$items, $artistItem;
		};

		$api->getUserFavorites(sub {
			my $favorites = shift;
			my $isFavorite = ($favorites && $favorites->{albums}) ? grep { $_->{id} eq $albumId } @{$favorites->{albums}->{items}} : 0;

			push @$items, {
				name => cstring($client, $isFavorite ? 'PLUGIN_QOBUZ_REMOVE_FAVORITE' : 'PLUGIN_QOBUZ_ADD_FAVORITE', $album->{title}),
				url  => $isFavorite ? \&QobuzDeleteFavorite : \&QobuzAddFavorite,
				image => 'html/images/favorites.png',
				passthrough => [{
					album_ids => $albumId
				}],
				nextWindow => 'parent'
			};

			if (my $item = trackInfoMenuBooklet($client, undef, undef, $album)) {
				push @$items, $item;
			}

			# Add a consolidated list of all artists on the album
			$items = _albumPerformers($client, $performers, $album->{tracks_count}, $items);

			push @$items,{
				name  => $album->{genre},
				label => 'GENRE',
				type  => 'text'
			},{
				name => $album->{release_type} =~ /^[a-z]+$/ ? ucfirst($album->{release_type}) : $album->{release_type},
				label => 'PLUGIN_QOBUZ_RELEASE_TYPE',
				type => 'text'
			},{
				name  => Slim::Utils::DateTime::timeFormat($album->{duration} || $totalDuration),
				label => 'ALBUMLENGTH',
				type  => 'text'
			},{
				name => $album->{tracks_count},
				label => 'PLUGIN_QOBUZ_TRACKS_COUNT',
				type => 'text'
			};

			if (defined $album->{replay_gain}) {
				push @$items,{
					name  => sprintf( "%2.2f dB", $album->{replay_gain}),
					label => 'ALBUMREPLAYGAIN',
					type => 'text'
				};
			};

			if ($album->{description}) {
				push @$items, {
					name  => cstring($client, 'DESCRIPTION'),
					items => [{
						name => _stripHTML($album->{description}),
						type => 'textarea',
					}],
				};
			};

			my $rDate = _localDate($album->{release_date_stream});
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . $rDate,
				type  => 'text'
			};

			if ($album->{label} && $album->{label}->{name}) {
				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $album->{label}->{name},
					url   => \&QobuzLabel,
					passthrough => [{
						labelId  => $album->{label}->{id},
					}],
				};
			}

			my $awards = $album->{awards};
			if ($awards && ref $awards && scalar @$awards) {
				my $awItems = [ map {
					{
						name => Slim::Utils::DateTime::shortDateF($_->{awarded_at}) . ' - ' . $_->{name},
						type => 'text'
					}
				} @$awards ];

				push @$items, {
					name  => cstring($client, 'PLUGIN_QOBUZ_AWARDS'),
					items => $awItems
				};
			}

			if ($album->{copyright}) {
				push @$items, {
					name  => 'Copyright',
					items => [{
						name => $album->{copyright},
						type => 'textarea',
					}],
				};
			};

			$cb->({
				items => $items,
			}, @_ );
		});
	}, $albumId);
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

sub QobuzWorkGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $tracks = $args->{tracks};

	$cb->({
		type => 'playlist',
		playall => 1,
		items => $tracks
	});
}

sub QobuzPlaylistGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $playlistId = $args->{playlist_id};

	getAPIHandler($client)->getPlaylistTracks(sub {
		my $playlist = shift;

		if (!$playlist) {
			$log->error("Get playlist ($playlistId) failed");
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

sub _albumItem {
	my ($client, $album) = @_;

	my $artist = $album->{artist}->{name} || '';
	my $albumName = $album->{title} || '';
	my $showYearWithAlbum = $prefs->get('showYearWithAlbum');
	my $albumYear = $showYearWithAlbum ? $album->{year} || substr($album->{release_date_stream},0,4) || 0 : 0;

	if ( $album->{hires_streamable} && $albumName !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($album) eq 'flac' ) {
		$albumName .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
	}

	my $item = {
		image => $album->{image},
	};

	my $sortFavsAlphabetically = $prefs->get('sortFavsAlphabetically') || 0;
	if ($sortFavsAlphabetically == 1) {
		$item->{name} = $albumName . ($artist ? ' - ' . $artist : '');
	}
	else {
		$item->{name} = $artist . ($artist && $albumName ? ' - ' : '') . $albumName;
	}

	if ($albumName) {
		$item->{line1} = $albumName;
		$item->{line2} = $artist . ($albumYear ? ' (' . $albumYear . ')' : '');
		$item->{name} .= $albumYear ? "\n(" . $albumYear . ')' : '';
	}

	if ( $prefs->get('parentalWarning') && $album->{parental_warning} ) {
		$item->{name} .= ' [E]';
		$item->{line1} .= ' [E]';
	}

	if (!$album->{streamable} || !_isReleased($album) ) {
		$item->{name}  = '* ' . $item->{name};
		$item->{line1} = '* ' . $item->{line1};
	} else {
		$item->{type}        = 'playlist';
	}

	$item->{url}         = \&QobuzGetTracks;
	$item->{passthrough} = [{
		album_id => $album->{id},
		album_title => $album->{title},
	}];

	return $item;
}

sub _artistItem {
	my ($client, $artist, $withIcon) = @_;

	my $item = {
		name  => $artist->{name},
		url   => \&QobuzArtist,
		passthrough => [{
			artistId  => $artist->{id},
		}],
	};

	$item->{image} = $artist->{picture} || getAPIHandler($client)->getArtistPicture($artist->{id}) || 'html/images/artists.png' if $withIcon;

	return $item;
}

sub _playlistItem {
	my ($playlist, $showOwner, $isWeb) = @_;

	my $image = Plugins::Qobuz::API::Common->getPlaylistImage($playlist);

	my $owner = $showOwner ? $playlist->{owner}->{name} : undef;

	return {
		name  => $playlist->{name} . ($isWeb && $owner ? " - $owner" : ''),
		name2 => $owner,
		url   => \&QobuzPlaylistGetTracks,
		image => $image,
		passthrough => [{
			playlist_id  => $playlist->{id},
		}],
		type  => 'playlist',
	};
}

sub _trackItem {
	my ($client, $track, $isWeb) = @_;

	my $title = Plugins::Qobuz::API::Common->addVersionToTitle($track);
	my $artist = Plugins::Qobuz::API::Common->getArtistName($track, $track->{album});
	my $album  = $track->{album}->{title} || '';
	if ( $track->{album}->{title} && $prefs->get('showDiscs') ) {
		$album = Slim::Music::Info::addDiscNumberToAlbumTitle($album,$track->{media_number},$track->{album}->{media_count});
	}
	my $genre = $track->{album}->{genre};

	my $item = {
		name  => sprintf('%s %s %s %s %s', $title, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $album),
		line1 => $title,
		line2 => $artist . ($artist && $album ? ' - ' : '') . $album,
		image => Plugins::Qobuz::API::Common->getImageFromImagesHash($track->{album}->{image}),
	};

	if ( $track->{hires_streamable} && $item->{name} !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($track->{album}) eq 'flac' ) {
		$item->{name} .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
		$item->{line1} .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
	}

	# Enhancements to work/composer display for classical music (tags returned from Qobuz are all over the place)
	if ( $track->{album}->{isClassique} ) {
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

	if ( $track->{album} ) {
		$item->{year} = $track->{album}->{year} || substr($track->{$album}->{release_date_stream},0,4) || 0;
	}

	if ( $prefs->get('parentalWarning') && $track->{parental_warning} ) {
		$item->{name} .= ' [E]';
		$item->{line1} .= ' [E]';
	}

	if (!$track->{streamable} && (!$prefs->get('playSamples') || !$track->{sampleable})) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
			type => 'textarea'
		}];
		$item->{name}      = '* ' . $item->{name};
		$item->{line1}     = '* ' . $item->{line1};
	}
	else {
		$item->{name}      = '* ' . $item->{name} if !$track->{streamable};
		$item->{line1}     = '* ' . $item->{line1} if !$track->{streamable};
		$item->{play}      = Plugins::Qobuz::API::Common->getUrl($client, $track);
		$item->{on_select} = 'play';
		$item->{playall}   = 1;
	}

	$item->{tracknum} = $track->{track_number};
	$item->{media_number} = $track->{media_number};
	$item->{media_count} = $track->{album}->{media_count};
	return $item;
}

sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title}  : $track->title;
	my $label  = $track->remote ? $remoteMeta->{label} : undef;
	my $labelId = $track->remote ? $remoteMeta->{labelId} : undef;
	my $composer  = $track->remote ? [$remoteMeta->{composer}] : undef;
	my $work = $composer && $remoteMeta->{work} ? ["$remoteMeta->{composer} $remoteMeta->{work}"] : undef;

	my $items;

	if ( my ($trackId) = Plugins::Qobuz::ProtocolHandler->crackUrl($url) ) {
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

			$items ||= [];
			push @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_MANAGE_FAVORITES'),
				url  => \&QobuzManageFavorites,
				passthrough => [$args],
			} if keys %$args
		}

		if (my $item = trackInfoMenuPerformers($client, undef, undef, $remoteMeta)) {
			push @$items, $item
		}

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
		}, $albumId) unless $qobuzAlbum;

		if ( $qobuzAlbum ) {
			my %seen;
			foreach my $track (@{$qobuzAlbum->{tracks}->{items}}) {
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

			my $performers = {};
			foreach my $track (@{$qobuzAlbum->{tracks}->{items}}) {
				if (my $trackPerformers = trackInfoMenuPerformers($client, undef, undef, $track)) {
					my $performerItems = $trackPerformers->{items};
					foreach my $item (@$performerItems) {
						$item->{'track'} = $track->{'track_number'};
					}
					push @{$performers->{$track->{'media_number'}}}, @$performerItems;
				}
			}

			$items = _albumPerformers($client, $performers, $qobuzAlbum->{tracks_count}, $items);

			if (my $item = trackInfoMenuBooklet($client, undef, undef, $qobuzAlbum)) {
				push @$items, $item
			}
		}
	}

	return _objInfoHandler( $client, $artists[0]->name, $albumTitle, undef, $items, $label, $labelId, $composers, $works);
}

sub _objInfoHandler {
	my ( $client, $artist, $album, $track, $items, $label, $labelId, $composer, $work ) = @_;

	$items ||= [];

	my $nameType = {};
	$nameType->{$artist} = cstring($client, 'ARTIST');
	$nameType->{$album} = cstring($client, 'ALBUM');
	$nameType->{$track} = cstring($client, 'TRACK');
	$nameType->{$_} = cstring($client, 'COMPOSER') foreach @$composer;
	$nameType->{$_} = cstring($client, 'PLUGIN_QOBUZ_WORK') foreach @$work;

	my %seen;
	foreach ($artist, $album, $track, @$composer, @$work) {
		# prevent duplicate entries if eg. album & artist have the same name
		next if $seen{$_};

		$seen{$_} = 1;

		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SEARCH', $nameType->{$_}, $_),
			url  => \&QobuzSearch,
			passthrough => [{
				q => $_,
			}]
		} if $_;
	}

	push @$items, {
		name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $label,
		url   => \&QobuzLabel,
		passthrough => [{
			labelId  => $labelId,
		}],
	} if $label && $labelId;

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

my $MAIN_ARTIST_RE = qr/MainArtist|\bPerformer\b|ComposerLyricist/i;
my $ARTIST_RE = qr/Performer|Keyboards|Synthesizer|Vocal|Guitar|Lyricist|Composer|Bass|Drums|Percussion||Violin|Viola|Cello|Trumpet|Conductor|Trombone|Trumpet|Horn|Tuba|Flute|Euphonium|Piano|Orchestra|Clarinet|Didgeridoo|Cymbals|Strings|Harp/i;
my $STUDIO_RE = qr/StudioPersonnel|Other|Producer|Engineer|Prod/i;

sub trackInfoMenuPerformers {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	if ( $remoteMeta && (my $performers = $remoteMeta->{performers}) ) {
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
			$request->addResultLoop('item_loop', $i, 'text', _localizeGoodies($client, $_->{name}));
			$request->addResultLoop('item_loop', $i, 'weblink', $_->{url});
			$i++;
		}
	}

	$request->addResult('count', $i);
	$request->addResult('offset', 0);

	$request->setStatusDone();
}

sub searchMenu {
	my ( $client, $tags ) = @_;

	my $searchParam = $tags->{search};

	return {
		name => cstring($client, getDisplayName()),
		items => [{
			name  => cstring($client, 'ALBUMS'),
			url   => \&QobuzSearch,
			image => 'html/images/albums.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'albums',
			}],
		},{
			name  => cstring($client, 'ARTISTS'),
			url   => \&QobuzSearch,
			image => 'html/images/artists.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'artists',
			}],
		},{
			name  => cstring($client, 'SONGS'),
			url   => \&QobuzSearch,
			image => 'html/images/playlists.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'tracks',
			}],
		},{
			name  => cstring($client, 'PLAYLISTS'),
			url   => \&QobuzSearch,
			image => 'html/images/playlists.png',
			passthrough => [{
				q        => $searchParam,
				type     => 'playlists',
			}],
		}]
	};
}

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

	$clientOrId ||= Plugins::Qobuz::API::Common->getSomeUserId();

	my $api;

	if (ref $clientOrId) {
		$api = $clientOrId->pluginData('api');

		if ( !$api ) {
			# if there's no account assigned to the player, just pick one
			if ( !$prefs->client($clientOrId)->get('userId') ) {
				my $userId = Plugins::Qobuz::API::Common->getSomeUserId();
				$prefs->client($clientOrId)->set('userId', $userId) if $userId;
			}

			$api = $clientOrId->pluginData( api => Plugins::Qobuz::API->new({
				client => $clientOrId
			}) );
		}
	}
	else {
		$api = Plugins::Qobuz::API->new({
			userId => $clientOrId
		});
	}

	logBacktrace("Failed to get a Qobuz API instance: $clientOrId") unless $api;

	return $api;
}

1;
