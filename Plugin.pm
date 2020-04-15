package Plugins::Qobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS::VersionOneAndTwo;
use Tie::RegexpHash;

use Slim::Formats::RemoteMetadata;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::ProtocolHandler;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);
use constant CLICOMMAND => 'qobuzquery';

# Keep in sync with Music & Artist Information plugin
my $WEBLINK_SUPPORTED_UA_RE = qr/\b(?:iPeng|SqueezePad|OrangeSqueeze|Squeeze-Control)\b/i;
my $WEBBROWSER_UA_RE = qr/\b(?:FireFox|Chrome|Safari)\b/i;

my $GOODIE_URL_PARSER_RE = qr/\.(?:pdf|png|gif|jpg)$/i;

my $prefs = preferences('plugin.qobuz');

tie my %localizationTable, 'Tie::RegexpHash';

%localizationTable = (
	qr/^Livret Num.rique/i => 'PLUGIN_QOBUZ_BOOKLET'
);

$prefs->init({
	preferredFormat => 6,
	filterSearchResults => 0,
	playSamples => 1,
	dontImportPurchases => 1,
});

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.qobuz',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_QOBUZ',
	logGroups    => 'SCANNER',
} );

use constant PLUGIN_TAG => 'qobuz';
use constant CAN_IMAGEPROXY => (Slim::Utils::Versions->compareVersions($::VERSION, '7.8.0') >= 0);

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
	Slim::Menu::TrackInfo->registerInfoProvider( qobuzPerformers => (
		func  => \&trackInfoMenuPerformers,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( qobuzTrackInfo => (
		func  => \&trackInfoMenu,
		after => 'qobuzPerformers'
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( qobuzBooklet => (
		func  => \&trackInfoMenuBooklet,
		after => 'qobuzTrackInfo'
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( qobuzFrequency => (
		parent => 'moreinfo',
		after  => 'bitrate',
		func   => \&infoSamplerate,
	) );

	Slim::Menu::TrackInfo->registerInfoProvider( qobuzBitsperSample => (
		parent => 'moreinfo',
		after  => 'qobuzFrequency',
		func   => \&infoBitsperSample,
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
			Plugins::LastMix::Services->registerHandler('Plugins::Qobuz::LastMix', Plugins::Qobuz::API::Common->canLossless());
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

sub getDisplayName { 'PLUGIN_QOBUZ' }

# don't add this plugin to the Extras menu
sub playerMenu {}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	my $params = $args->{params};

	$cb->({
		items => ( $prefs->get('username') && $prefs->get('password_md5_hash') ) ? [{
			name  => cstring($client, 'SEARCH'),
			image => 'html/images/search.png',
			type => 'search',
			url  => sub {
				my ($client, $cb, $params) = @_;

				my $menu = searchMenu($client, {
					search => lc($params->{search})
				});

				$cb->({
					items => $menu->{items}
				});
			}
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
				type    => 'new-releases',
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
		}] : [{
			name => cstring($client, 'PLUGIN_QOBUZ_REQUIRES_CREDENTIALS'),
			type => 'textarea',
		}]
	});
}


sub QobuzSearch {
	my ($client, $cb, $params, $args) = @_;

	$args ||= {};
	$params->{search} ||= $args->{q};
	my $type   = lc($args->{type} || '');
	my $search = lc($params->{search});

	Plugins::Qobuz::API->search(sub {
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

	my $items = [];

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

	Plugins::Qobuz::API->getArtist(sub {
		my $artist = shift;

		if ($artist->{status} && $artist->{status} =~ /error/i) {
			$cb->();
			return;
		}

		my $items = [{
			name  => cstring($client, 'ALBUMS'),
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
				image => Plugins::Qobuz::API::Common->getImageFromImagesHash($images) || Plugins::Qobuz::API->getArtistPicture($artist->{id}) || 'html/images/artists.png',
				items => [{
					name => _stripHTML($artist->{biography}->{content}),
					type => 'textarea',
				}],
			}
		}

		# use album list if it was returned in the artist lookup
		if ($artist->{albums}) {
			my $albums = [];

			my $sortByDate = (preferences('server')->get('jivealbumsort') || '') eq 'artflow';

			$artist->{albums}->{items} = [ sort {

				# push singles and EPs down the list
				if ( ($a->{tracks_count} >= 4 && $b->{tracks_count} < 4) || ($a->{tracks_count} < 4 && $b->{tracks_count} >=4) ) {
					return $b->{tracks_count} <=> $a->{tracks_count};
				}

				return $a->{released_at}*1 <=> $b->{released_at}*1 if $sortByDate;
				return lc($a->{title}) cmp lc($b->{title});

			} @{$artist->{albums}->{items} || []} ];

			for my $album ( @{$artist->{albums}->{items}} ) {
				next if $args->{artistId} && $album->{artist}->{id} != $args->{artistId};
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

				Plugins::Qobuz::API->getSimilarArtists(sub {
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

		$cb->( {
			items => $items
		} );
	}, $args->{artistId});
}

sub QobuzGenres {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId} || '';

	Plugins::Qobuz::API->getGenres(sub {
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

	Plugins::Qobuz::API->getGenre(sub {
		my $genre = shift;

		if (!$genre) {
			$log->error("Get genre ($genreId) failed");
			return;
		}

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
				type    => 'new-releases',
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

		if ($genre->{subgenresCount}) {
			push @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_SUB_GENRES'),
				url  => \&QobuzGenres,
				image => 'html/images/genres.png',
				passthrough => [{
					genreId => $genreId,
				}]
			}
		}

		foreach my $album ( @{$genre->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}

		$cb->({
			items => $items
		});
	}, $genreId);
}


sub QobuzFeaturedAlbums {
	my ($client, $cb, $params, $args) = @_;
	my $type    = $args->{type};
	my $genreId = $args->{genreId};

	Plugins::Qobuz::API->getFeaturedAlbums(sub {
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

sub QobuzUserPurchases {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Qobuz::API->getUserPurchases(sub {
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

	Plugins::Qobuz::API->getUserFavorites(sub {
		my $favorites = shift;

		my $items = [];

		my @artists;
		for my $artist ( @{$favorites->{artists}->{items}} ) {
			push @artists, _artistItem($client, $artist, 'withIcon');
		}

		push @$items, {
			name => cstring($client, 'ARTISTS'),
		#	items => [ sort { lc($a->{name}) cmp lc($b->{name}) } @artists ],
			items => \@artists,		# don't sort, leave it the was it's displayed in the Qobuz Desktop, too
			image => 'html/images/artists.png',
		} if @artists;

		my @albums;
		for my $album ( @{$favorites->{albums}->{items}} ) {
			push @albums, _albumItem($client, $album);
		}

		push @$items, {
			name => cstring($client, 'ALBUMS'),
		#	items => [ sort { lc($a->{name}) cmp lc($b->{name}) } @albums ],
			items => \@albums,		# don't sort either (Pierre)
			image => 'html/images/albums.png',
		} if @albums;

		my @tracks;
		for my $track ( @{$favorites->{tracks}->{items}} ) {
			push @tracks, _trackItem($client, $track);
		}

		push @$items, {
			name => cstring($client, 'SONGS'),
		#	items => [ sort { lc($a->{name}) cmp lc($b->{name}) } @tracks ],
			items => \@tracks,		# don't sort either (Pierre)
			image => 'html/images/playlists.png',
		} if @tracks;

		$cb->( {
			items => $items
		} );
	});
}

sub QobuzManageFavorites {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Qobuz::API->getUserFavorites(sub {
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

	Plugins::Qobuz::API->createFavorite(sub {
		my $result = shift;
		$cb->({
			text        => $result->{status},
			showBriefly => 1,
			nextWindow  => 'grandparent',
		});
	}, $args);
}

sub QobuzDeleteFavorite {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Qobuz::API->deleteFavorite(sub {
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

	Plugins::Qobuz::API->getUserPlaylists(sub {
		_playlistCallback(shift, $cb, undef, $params->{isWeb});
	});
}

sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;

	my $genreId = $args->{genreId};
	my $tags    = $args->{tags};
	my $type    = $args->{type} || 'editor-picks';

	if ($type eq 'editor-picks' && !$genreId && !$tags) {
		Plugins::Qobuz::API->getTags(sub {
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
				Plugins::Qobuz::API->getPublicPlaylists(sub {
					_playlistCallback(shift, $cb, 'showOwner', $params->{isWeb});
				}, $type);
			}
		});
	}
	else {
		Plugins::Qobuz::API->getPublicPlaylists(sub {
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

sub infoSamplerate {
	my ( $client, $url, $track, $remoteMeta ) = @_;

	if ( my $sampleRate = $remoteMeta->{samplerate} ) {
		return {
			type  => 'text',
			label => 'SAMPLERATE',
			name  => sprintf('%.1f kHz', $sampleRate)
		};
	}
}

sub infoBitsperSample {
	my ( $client, $url, $track, $remoteMeta ) = @_;

	if ( my $samplesize = $remoteMeta->{samplesize} ) {
		return {
			type  => 'text',
			label => 'SAMPLESIZE',
			name  => $samplesize . ' ' . cstring($client, 'BITS'),
		};
	}
}

sub QobuzGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $albumId = $args->{album_id};

	Plugins::Qobuz::API->getAlbum(sub {
		my $album = shift;

		if (!$album) {
			$log->error("Get album ($albumId) failed");
			$cb->();
			return;
		}

		my $items = [];

		my $totalDuration = my $i = 0;
		my $works = {};
		foreach my $track (@{$album->{tracks}->{items}}) {
			$totalDuration += $track->{duration};
			my $formattedTrack = _trackItem($client, $track);

			if (my $work = delete $formattedTrack->{work}) {
				# Qobuz sometimes would f... up work names, randomly putting whitespace etc. in names - ignore them
				my $workId = Slim::Utils::Text::matchCase(Slim::Utils::Text::ignorePunct($work));
				$workId =~ s/\s//g;

				$works->{$workId} = {
					index => $i++,
					title => $work,
					image => $formattedTrack->{image},
					tracks => []
				} unless $works->{$workId};

				push @{$works->{$workId}->{tracks}}, $formattedTrack;
			}

			push @$items, $formattedTrack;
		}

		if (scalar keys %$works) {
			my $worksItems = [];
			foreach my $work (sort { $works->{$a}->{index} <=> $works->{$b}->{index} } keys %$works) {
				push @$worksItems, {
					name => $works->{$work}->{title},
					image => $works->{$work}->{image},
					type => 'playlist',
					playall => 1,
					items => $works->{$work}->{tracks}
				};
			}

			unshift @$items, {
				name => cstring($client, 'PLUGIN_QOBUZ_BY_WORK'),
				image => 'html/images/albums.png',
				items => $worksItems
			};
		}

		if (my $artistItem = _artistItem($client, $album->{artist}, 1)) {
			$artistItem->{label} = 'ARTIST';
			push @$items, $artistItem;
		}

		push @$items,{
			name  => $album->{genre},
			label => 'GENRE',
			type  => 'text'
		},{
			name  => Slim::Utils::DateTime::timeFormat($album->{duration} || $totalDuration),
			label => 'ALBUMLENGTH',
			type  => 'text'
		},{
			name => $album->{tracks_count},
			label => 'PLUGIN_QOBUZ_TRACKS_COUNT',
			type => 'text'
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

		if ($album->{goodies}) {
			my $item = trackInfoMenuBooklet($client, undef, undef, $album);
			push @$items, $item if $item;
		}

		push @$items, {
			name  => cstring($client, 'PLUGIN_QOBUZ_RELEASED_AT') . cstring($client, 'COLON') . ' ' . Slim::Utils::DateTime::shortDateF($album->{released_at}),
			type  => 'text'
		};

		if ($album->{label} && $album->{label}->{name}) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_LABEL') . cstring($client, 'COLON') . ' ' . $album->{label}->{name},
				type  => 'text'
			};
		}

		if ($album->{awards} && ref $album->{awards}) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_QOBUZ_AWARDS') . cstring($client, 'COLON') . ' ' . join(', ', map { $_->{name} } @{$album->{awards}}),
				type  => 'text'
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
		}

		$cb->({
			items => $items,
		}, @_ );
	}, $albumId);
}

sub QobuzPlaylistGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $playlistId = $args->{playlist_id};

	Plugins::Qobuz::API->getPlaylistTracks(sub {
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

	if ( $album->{hires_streamable} && $albumName !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($album) eq 'flac' ) {
		$albumName .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
	}

	my $item = {
		name  => $artist . ($artist && $albumName ? ' - ' : '') . $albumName,
		image => $album->{image},
	};

	if ($albumName) {
		$item->{line1} = $albumName;
		$item->{line2} = $artist;
	}

	if ( $album->{released_at} > time  || (!$album->{streamable} && !$prefs->get('playSamples')) ) {
		my $sorry = ' (' . cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE') . ')';
		$item->{name}  .= $sorry;
		$item->{line2} .= $sorry;
		delete $item->{type};
		$item->{type} = 'text';
		delete $item->{url};
	}
	else {
		$item->{name}        = '* ' . $item->{name} if !$album->{streamable};
		$item->{line1}       = '* ' . $item->{line1} if !$album->{streamable};
		$item->{type}        = 'playlist';
		$item->{url}         = \&QobuzGetTracks;
		$item->{passthrough} = [{
			album_id => $album->{id},
		}];
	}

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

	$item->{image} = $artist->{picture} || Plugins::Qobuz::API->getArtistPicture($artist->{id}) || 'html/images/artists.png' if $withIcon;

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

	my $artist = Plugins::Qobuz::API::Common->getArtistName($track, $track->{album});
	my $album  = $track->{album}->{title} || '';

	my $item = {
		name  => sprintf('%s %s %s %s %s', $track->{title}, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $album),
		line1 => $track->{title},
		line2 => $artist . ($artist && $album ? ' - ' : '') . $album,
		image => Plugins::Qobuz::API::Common->getImageFromImagesHash($track->{album}->{image}),
	};

	if ( $track->{hires_streamable} && $item->{name} !~ /hi.?res|bits|khz/i && $prefs->get('labelHiResAlbums') && Plugins::Qobuz::API::Common->getStreamingFormat($track->{album}) eq 'flac' ) {
		$item->{name} .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
		$item->{line1} .= ' (' . cstring($client, 'PLUGIN_QOBUZ_HIRES') . ')';
	}

	if ( $track->{work} ) {
		$item->{work} = $track->{work};
	}

	if ($track->{released_at} && $track->{released_at} > time) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED'),
			type => 'textarea'
		}];
	}
	elsif (!$track->{streamable} && !$prefs->get('playSamples')) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
			type => 'textarea'
		}];
	}
	else {
		$item->{name}      = '* ' . $item->{name} if !$track->{streamable};
		$item->{line1}     = '* ' . $item->{line1} if !$track->{streamable};
		$item->{play}      = Plugins::Qobuz::API::Common->getUrl($track);
		$item->{on_select} = 'play';
		$item->{playall}   = 1;
	}

	return $item;
}

sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title}  : $track->title;

	my $items;

	if ( my ($trackId) = Plugins::Qobuz::ProtocolHandler->crackUrl($url) ) {
		my $albumId = $remoteMeta ? $remoteMeta->{albumId} : undef;
		my $artistId= $remoteMeta ? $remoteMeta->{artistId} : undef;

		if ($trackId || $albumId || $artistId) {
			my $args = ();
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
			}
		}
	}

	return _objInfoHandler( $client, $artist, $album, $title, $items );
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

	return _objInfoHandler( $client, $artists[0]->name, $albumTitle );
}

sub _objInfoHandler {
	my ( $client, $artist, $album, $track, $items ) = @_;

	$items ||= [];

	my %seen;
	foreach ($artist, $album, $track) {
		# prevent duplicate entries if eg. album & artist have the same name
		next if $seen{$_};

		$seen{$_} = 1;

		push @$items, {
			name => cstring($client, 'PLUGIN_QOBUZ_SEARCH', $_),
			url  => \&QobuzSearch,
			passthrough => [{
				q => $_,
			}]
		} if $_;
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
				type => 'text'
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
}

sub trackInfoMenuBooklet {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	eval {
		if ( my $goodies = $remoteMeta->{goodies} ) {
			# jive clients like iPeng etc. can display web content, but need special handling...
			if ( _canWeblink($client) )  {
				return {
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
			else {
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
					return {
						name => cstring($client, 'PLUGIN_QOBUZ_GOODIES'),
						items => $items
					};
				}
			}
		}
	};
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

	Plugins::Qobuz::API->getAlbum(sub {
		my $album = shift;

		if (!$album) {
			$log->error("Get album ($albumId) failed");
			return;
		}

		my $tracks = [];

		foreach my $track (@{$album->{tracks}->{items}}) {
			push @$tracks, Plugins::Qobuz::API::Common->getUrl($track);
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

1;
