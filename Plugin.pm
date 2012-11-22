package Plugins::Qobuz::Plugin;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Formats::RemoteMetadata;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Qobuz::API;
use Plugins::Qobuz::Settings;
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
	
	Plugins::Qobuz::Settings->new if main::WEBUI;
	
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
		items => [{
			name  => cstring($client, 'SEARCH'),
			image => 'html/images/search.png',
			type => 'search',
			url  => \&QobuzSearch
		},{
			name => $client->string('PLUGIN_QOBUZ_USERPURCHASES'),
			url  => \&QobuzUserPurchases,
			image => 'html/images/albums.png'
		},{
			name => $client->string('PLUGIN_QOBUZ_USER_FAVORITES'),
			url  => \&QobuzUserFavorites,
			image => 'html/images/albums.png'
		},{
			name => $client->string('PLUGIN_QOBUZ_USERPLAYLISTS'),
			url  => \&QobuzUserPlaylists,
			image => 'html/images/playlists.png'
		},{
			name => $client->string('PLUGIN_QOBUZ_PUBLICPLAYLISTS'),
			url  => \&QobuzPublicPlaylists,
			image => 'html/images/playlists.png'
		},{
			name => $client->string('PLUGIN_QOBUZ_BESTSELLERS'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				type    => 'best-sellers',
			}]
		},{
			name => $client->string('PLUGIN_QOBUZ_NEW_RELEASES'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				type    => 'new-releases',
			}]
		},{
			name => $client->string('PLUGIN_QOBUZ_PRESS'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				type    => 'press-awards',
			}]
		},{
			name => $client->string('PLUGIN_QOBUZ_EDITOR_PICKS'),
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
		}],
	});
}


sub QobuzSearch {
	my ($client, $cb, $params, $args) = @_;
	
	$params->{search} ||= $args->{q};
	
	my $search = lc($params->{search});
		
	Plugins::Qobuz::API->search(sub {
		my $searchResult = shift;
		
		if (!$searchResult || !$searchResult->{albums}) {
			$cb->();
		}
	
		my $albums = [];
			
		for my $album ( @{$searchResult->{albums}->{items}} ) {
			push @$albums, _albumItem($album);
		}
			
		$cb->( { 
			items => $albums
		} );
	}, $search);
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
			name => $client->string('PLUGIN_QOBUZ_BESTSELLERS'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				genreId => $genreId,
				type    => 'best-sellers',
			}]
		},{
			name => $client->string('PLUGIN_QOBUZ_NEW_RELEASES'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				genreId => $genreId,
				type    => 'new-releases',
			}]
		},{
			name => $client->string('PLUGIN_QOBUZ_PRESS'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				genreId => $genreId,
				type    => 'press-awards',
			}]
		},{
			name => $client->string('PLUGIN_QOBUZ_EDITOR_PICKS'),
			url  => \&QobuzFeaturedAlbums,
			image => 'html/images/albums.png',
			passthrough => [{
				genreId => $genreId,
				type    => 'editor-picks',
			}]
		}];
	
		if ($genre->{subgenresCount}) {
			push @$items, {
				name => $client->string('PLUGIN_QOBUZ_SUB_GENRES'),
				url  => \&QobuzGenres,
				image => 'html/images/genres.png',
				passthrough => [{
					genreId => $genreId,
				}]
			}
		}
		
		foreach my $album ( @{$genre->{albums}->{items}} ) {
			push @$items, _albumItem($album);
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
			push @$items, _albumItem($album);
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
			push @$items, _albumItem($album);
		}
			
		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			push @$items, _trackItem($track);
		}
		
		$cb->( { 
			items => $items
		} );
	});
}

sub QobuzUserFavorites {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Qobuz::API->getUserFavorites(sub {
		my $searchResult = shift;
			
		my $items = [];
			
		for my $album ( @{$searchResult->{albums}->{items}} ) {
			push @$items, _albumItem($album);
		}
			
		for my $track ( @{$searchResult->{tracks}->{items}} ) {
			push @$items, _trackItem($track);
		}
		
		$cb->( { 
			items => $items
		} );
	});
}

sub QobuzUserPlaylists {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Qobuz::API->getUserPlaylists(sub {
		my $searchResult = shift;
			
		my $playlists = [];
			
		for my $playlist ( @{$searchResult->{playlists}->{items}} ) {
			push @$playlists, _playlistItem($playlist);
		}
			
		$cb->( { 
			items => $playlists
		} );
	});
}

sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Qobuz::API->getPublicPlaylists(sub {
		my $searchResult = shift;
			
		my $playlists = [];
			
		for my $playlist ( @{$searchResult} ) {
			push @$playlists, _playlistItem($playlist, 'showOwner');
		}
			
		$cb->( { 
			items => $playlists
		} );
	});
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
			push @$tracks, _trackItem($track);
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
			push @$tracks, _trackItem($track);
		}
	
		$cb->({
			items => $tracks,
		}, @_ );
	}, $playlistId);
}

sub _albumItem {
	my ($album) = @_;
	
	my $artist = $album->{artist}->{name} || '';
	my $albumName = $album->{title} || '';

	return {
		name  => $artist . ($artist && $albumName ? ' - ' : '') . $albumName,
		url   => \&QobuzGetTracks,
		image => $album->{image}->{large},
		passthrough => [{ 
			album_id  => $album->{id},
		}],
		type  => 'playlist',
	};
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
	my ($track) = @_;

	my $artist = $track->{album}->{artist}->{name} || $track->{performer}->{name} || '';
	my $album  = $track->{album}->{title} || '';

	return {
		name  => $track->{title},
		name2 => $artist . ($artist && $album ? ' - ' : '') . $album,
		play  => 'qobuz://' . $track->{id},
		image => $track->{album}->{image}->{large} || $track->{album}->{image}->{small},
		on_select   => 'play',
		playall     => 1,
	};
}

sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta, $tags ) = @_;

	my $artist = $track->remote ? $remoteMeta->{artist} : $track->artistName;
	my $album  = $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef );
	my $title  = $track->remote ? $remoteMeta->{title}  : $track->title;

	return _objInfoHandler( $client, $artist, $album, $title );
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
	my ( $client, $artist, $album, $track ) = @_;

	my $items = [];

	foreach ($artist, $album, $track) {
		push @$items, {
			name => $_,
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