package Plugins::Qobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Formats::RemoteMetadata;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Qobuz::API;
use Plugins::Qobuz::ProtocolHandler;

my $prefs = preferences('plugin.qobuz');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.qobuz',
	defaultLevel => 'ERROR',
	description  => 'PLUGIN_QOBUZ',
} );

use constant PLUGIN_TAG => 'qobuz';

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
	
	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr|\.qobuz\.com/|, 
		sub { $class->_pluginDataFor('icon') }
	);

	# Track Info item
	Slim::Menu::TrackInfo->registerInfoProvider( qobuz => (
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( qobuz => (
		func => \&artistInfoMenu,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( qobuz => (
		func => \&albumInfoMenu,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( qobuz => (
		func => \&searchMenu,
	) );
	
	Slim::Control::Request::addDispatch(['qobuz', 'playalbum'], [1, 0, 0, \&cliQobuzPlayAlbum]);
	
	if ( Slim::Utils::PluginManager->isEnabled('Plugins::SmartMix::Plugin') ) {
		eval {
			require Plugins::SmartMix::Services;
		};
		
		if (!$@) {
			main::INFOLOG && $log->info("SmartMix plugin is available - let's use it!");
			require Plugins::Qobuz::SmartMix;
			Plugins::SmartMix::Services->registerHandler('Plugins::Qobuz::SmartMix');
		}
	}
	
	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => PLUGIN_TAG,
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);
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
			url  => \&QobuzSearch
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
			image => 'html/images/playlists.png'
		},{
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
		}

		my $albums = [];
		for my $album ( @{$searchResult->{albums}->{items}} ) {
			# XXX - unfortunately the album results don't return the artist's ID
			next if $args->{artistId} && !($album->{artist} && lc($album->{artist}->{name}) eq $search);
			push @$albums, _albumItem($client, $album);
		}

		my $artists = [];
		for my $artist ( @{$searchResult->{artists}->{items}} ) {
			push @$artists, _artistItem($client, $artist);
		}

		my $tracks = [];
		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			next if $args->{artistId} && !($track->{performer} && $track->{performer}->{id} eq $args->{artistId});
			push @$tracks, _trackItem($client, $track);
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

		if (scalar @$items == 1) {
			$items = $items->[0]->{items};
		}

		$cb->( { 
			items => $items
		} );
	}, $search, $type);
}

sub QobuzArtist {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Qobuz::API->getArtist(sub {
		my $artist = shift;
		
		if ($artist->{status} && $artist->{status} =~ /error/i) {
			$cb->();
		}
		
		my $items = [{
			name  => cstring($client, 'ALBUMS'),
			url   => \&QobuzSearch,
			image => 'html/images/artists.png',
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
				image => $images->{mega} || $images->{extralarge} || $images->{large} || $images->{medium} || $images->{small} || 'html/images/artists.png',
				items => [{
					name => $artist->{biography}->{summary} || $artist->{biography}->{content},
					type => 'textarea',
				}],
			}
		}
		
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
			
		for my $artist ( @{$favorites->{artists}->{items}} ) {
			push @$items, _artistItem($client, $artist, 'withIcon');
		}
			
		for my $album ( @{$favorites->{albums}->{items}} ) {
			push @$items, _albumItem($client, $album);
		}
			
		for my $track ( @{$favorites->{tracks}->{items}} ) {
			push @$items, _trackItem($client, $track);
		}
		
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
		_playlistCallback(shift, $cb);
	});
}

sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Qobuz::API->getPublicPlaylists(sub {
		_playlistCallback(shift, $cb, 'showOwner');
	});
}

sub _playlistCallback {
	my ($searchResult, $cb, $showOwner) = @_;
			
	my $playlists = [];
			
	for my $playlist ( @{$searchResult->{playlists}->{items}} ) {
		push @$playlists, _playlistItem($playlist, $showOwner);
	}
			
	$cb->( { 
		items => $playlists
	} );
}

sub QobuzGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $albumId = $args->{album_id};
	
	Plugins::Qobuz::API->getAlbum(sub {
		my $album = shift;
		
		if (!$album) {
			$log->error("Get album ($albumId) failed");
			$cb->();
		}
		
		my $tracks = [];
	
		foreach my $track (@{$album->{tracks}->{items}}) {
			push @$tracks, _trackItem($client, $track);
		}
	
		$cb->({
			items => $tracks,
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
			push @$tracks, _trackItem($client, $track);
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
	
	my $item = {
		name  => $artist . ($artist && $albumName ? ' - ' : '') . $albumName,
		image => $album->{image}->{large},
	};
	
	if ($album->{released_at} > time) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED'),
			type => 'textarea'
		}];
	}
	else {
		$item->{type} = 'playlist';
		$item->{url}  = \&QobuzGetTracks;
		$item->{passthrough} = [{ 
			album_id  => $album->{id},
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
	
	$item->{image} = 'html/images/artists.png' if $withIcon;
	
	return $item;
}

sub _playlistItem {
	my ($playlist, $showOwner) = @_;
	
	return {
		name  => $playlist->{name},
		name2 => $showOwner ? $playlist->{owner}->{name} : undef,
		url   => \&QobuzPlaylistGetTracks,
		image => 'html/images/playlists.png',
		passthrough => [{ 
			playlist_id  => $playlist->{id},
		}],
		type  => 'playlist',
	};
}

sub _trackItem {
	my ($client, $track) = @_;

	my $artist = $track->{album}->{artist}->{name} || $track->{performer}->{name} || '';
	my $album  = $track->{album}->{title} || '';

	my $item = {
		name  => $track->{title},
		name2 => $artist . ($artist && $album ? ' - ' : '') . $album,
		image => $track->{album}->{image}->{large} || $track->{album}->{image}->{small},
	};

	if ($track->{released_at} > time) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_RELEASED'),
			type => 'textarea'
		}];
	}
	elsif (!$track->{streamable}) {
		$item->{items} = [{
			name => cstring($client, 'PLUGIN_QOBUZ_NOT_AVAILABLE'),
			type => 'textarea'
		}];
	}
	else {
		$item->{play}      = 'qobuz://' . $track->{id};
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
	
	if ( $url =~ m|^qobuz://(.*)| ) {
		my $trackId = $1;
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

sub searchMenu {
	my ( $client, $tags ) = @_;
	
	return {
		name => cstring($client, getDisplayName()),
		url  => \&QobuzSearch,
		search => $tags->{search},
	};
}

sub cliQobuzPlayAlbum {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotCommand([['qobuz'], ['playalbum']])) {
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
			push @$tracks, 'qobuz://' . $track->{id};
		}
	
		$client->execute( ["playlist", "playtracks", "listref", $tracks] );
	}, $albumId);

	$request->setStatusDone();
}

1;