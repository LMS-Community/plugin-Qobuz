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
	Plugins::Qobuz::Settings->new;

	Slim::Player::ProtocolHandlers->registerHandler(
		qobuz => 'Plugins::Qobuz::ProtocolHandler'
	);
	
	Slim::Player::ProtocolHandlers->registerIconHandler(
		qr|\.qobuz\.com/|, 
		sub { $class->_pluginDataFor('icon') }
	);
	
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
	
	my $search = $params->{search};
		
	my $searchResult = Plugins::Qobuz::API->search($search);
		
	my $albums = [];
		
	for my $album ( @{$searchResult->{albums}->{items}} ) {
		push @$albums, _albumItem($album);
	}
		
	$cb->( { 
		items => $albums
	} );
}


sub QobuzGenres {
	my ($client, $cb, $params, $args) = @_;
	
	my $genreId = $args->{genreId} || '';

	my $genres = Plugins::Qobuz::API->getGenres($genreId);
	
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
}


sub QobuzGenre {
	my ($client, $cb, $params, $args) = @_;
	
	my $genreId = $args->{genreId} || '';

	my $genre = Plugins::Qobuz::API->getGenre($genreId);
	
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
	})	
}


sub QobuzFeaturedAlbums {
	my ($client, $cb, $params, $args) = @_;
	my $type    = $args->{type};
	my $genreId = $args->{genreId};
	
	my $albums = Plugins::Qobuz::API->getFeaturedAlbums($type, $genreId);
	
	my $items = [];
	
	foreach my $album ( @{$albums->{albums}->{items}} ) {
		push @$items, _albumItem($album);
	}
	
	$cb->({
		items => $items
	})	
}

sub QobuzUserPurchases {
	my ($client, $cb, $params, $args) = @_;
	
	my $searchResult = Plugins::Qobuz::API->getUserPurchases();
		
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
}

sub QobuzUserPlaylists {
	my ($client, $cb, $params, $args) = @_;
	
	my $searchResult = Plugins::Qobuz::API->getUserPlaylists();
		
	my $playlists = [];
		
	for my $playlist ( @{$searchResult->{playlists}->{items}} ) {
		push @$playlists, _playlistItem($playlist);
	}
		
	$cb->( { 
		items => $playlists
	} );
}

sub QobuzPublicPlaylists {
	my ($client, $cb, $params, $args) = @_;
	
	my $searchResult = Plugins::Qobuz::API->getPublicPlaylists();
		
	my $playlists = [];
		
	for my $playlist ( @{$searchResult} ) {
		push @$playlists, _playlistItem($playlist, 'showOwner');
	}
		
	$cb->( { 
		items => $playlists
	} );
}

sub QobuzGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $albumId = $args->{album_id};
	
	$log->debug($albumId);
	
	my $album = Plugins::Qobuz::API->getAlbum($albumId);
	
	if (!$album) {
		$log->error("Get album ($albumId) failed");
		return;
	}
	
	my $tracks = [];

	foreach my $track (@{$album->{tracks}->{items}}) {
		push @$tracks, _trackItem($track);
	}

	$cb->({
		items => $tracks,
	}, @_ );
}

sub QobuzPlaylistGetTracks {
	my ($client, $cb, $params, $args) = @_;
	my $playlistId = $args->{playlist_id};
	
	$log->debug($playlistId);
	
	my $playlist = Plugins::Qobuz::API->getPlaylistTracks($playlistId);
	
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
}

sub _albumItem {
	my ($album) = @_;
	
	return {
		name  => $album->{artist}->{name} . " - " . $album->{title},
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

	main::DEBUGLOG && $log->debug(" track id " . $track->{id});

	return {
		name  => $track->{title},
		name2 => $track->{album}->{artist}->{name} . " - " . $track->{album}->{title},
		play  => 'qobuz://' . $track->{id},
		image => $track->{album}->{image}->{large},
		on_select   => 'play',
		playall     => 1,
	};
}

1;