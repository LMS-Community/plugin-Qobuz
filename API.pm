package Plugins::Qobuz::API;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use LWP::UserAgent;
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);

use constant BASE_URL => 'http://player.qobuz.com/api.json/0.2/';
use constant TRACK_URL_TTL => 600;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# bump the second parameter if you decide to change the schema of cached data
my $cache = Slim::Utils::Cache->new('qobuz', 3);
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my $ua = LWP::UserAgent->new(timeout => 15);

sub getToken {
	my $username = $prefs->get('username');
	my $password = $prefs->get('password_md5_hash');

	if (my $token = $cache->get('token_' . $username . $password)) {
		return $token;
	}
	
	my $result = _call('/user/login', {
		username => $username,
		password => $password,
	});

	my $token;
	if ( ! ($result && ($token = $result->{user_auth_token})) ) {
		$cache->set('token', -1, 30);
		return;
	}

	$cache->set('username', $result->{user}->{login} || $username) if $result->{user};
	$cache->set('token_' . $username . $password, $token);

	return $token;
}

sub username {
	return $cache->get('username') || $prefs->get('username');
}

sub search {
	my ($class, $search) = @_;
	
	main::DEBUGLOG && $log->debug('Search : ' . $search);
	
	return _call('search/getResults', {
		type  => 'albums',
		query => $search, 
		limit => 200,
	});
}

sub getGenres {
	my ($class, $genreId) = @_;
	
	return _call('genre/list', {
		parent_id => $genreId
	});
}

sub getGenre {
	my ($class, $genreId) = @_;
	
	return _call('genre/get', {
		genre_id => $genreId,
		extra => 'subgenresCount,albums',
	});
}

sub getAlbum {
	my ($class, $albumId) = @_;
	
	my $album = _call('album/get', {
		album_id => $albumId,
	});
	
	_precacheAlbum([$album]) if $album;
	
	return $album;
}

sub getFeaturedAlbums {
	my ($class, $type, $genreId) = @_;
	
	my $albums = _call('album/getFeatured', {
		type     => $type,
		genre_id => $genreId,
		limit    => 200,
		_ttl     => 60*60,		# features can change quite often - don't cache for too long
	});
	
	_precacheAlbum($albums->{albums}->{items}) if $albums->{albums};
	
	return $albums;
}

sub getUserPurchases {
	my ($class) = @_;
	
	my $purchases = _call('purchase/getUserPurchases', {
		user_auth_token => getToken,
		limit    => 200,
		_ttl     => 2*60,		# don't cache user-controlled content for too long...
	});
	
	_precacheAlbum($purchases->{albums}->{items}) if $purchases->{albums};
	_precacheTracks($purchases->{tracks}->{items}) if $purchases->{tracks};
	
	return $purchases;
}

sub getUserPlaylists {
	my ($class, $user) = @_;
	
	my $playlists = _call('playlist/getUserPlaylists', {
		user_auth_token => getToken,
		username => $user || __PACKAGE__->username,
		limit    => 200,
		_ttl     => 2*60,		# user playlists can change quite often - don't cache for too long
	});
	
	return $playlists;
}

sub getPublicPlaylists {
	my ($class) = @_;
	
	my $playlists = _call('playlist/getPublicPlaylists', {
		user_auth_token => getToken,
		type  => 'last-created',
		limit => 200,
		_ttl  => 60*60
	});

	return $playlists;
}

sub getPlaylistTracks {
	my ($class, $playlistId) = @_;

	my $tracks = _call('playlist/get', {
		playlist_id => $playlistId,
		extra => 'tracks',
		user_auth_token => getToken,
		_ttl  => 2*60,
	});
	
	_precacheTracks($tracks->{tracks}->{items});
	
	return $tracks;
}

sub getTrackInfo {
	my ($class, $trackId) = @_;

	return unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}
	
	my $meta = $cache->get('trackInfo_' . $trackId);
	
	if (!$meta) {
		$meta = _call('track/get', {
			track_id => $trackId
		});
		
		$meta = _precacheTrack($meta) if $meta;
	}
	
	return $meta;
}

sub getFileUrl {
	my ($class, $trackId) = @_;
	return $class->getFileInfo($trackId, 'url');
}

sub getFileInfo {
	my ($class, $trackId, $urlOnly, $noPrefetch) = @_;

	return unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}
	
	if (my $cached = $cache->get($urlOnly ? "trackUrl_$trackId" : "fileInfo_$trackId")) {
		return $cached;
	}
	
	return if $noPrefetch;
	
	my $track = _call('track/getFileUrl', {
		track_id => $trackId,
		format_id => $prefs->get('preferredFormat'),
		user_auth_token => getToken,
		_ttl  => 30,
		_sign => 1,
	});
	
	if ($track) {
		my $url = delete $track->{url};

		# cache urls for a short time only
		$cache->set("trackUrl_$trackId", $url, TRACK_URL_TTL);
		$cache->set('trackId_' . $url, $trackId);
		$cache->set("fileInfo_$trackId", $track);
		return $urlOnly ? $url : $track;
	}
}

sub _precacheAlbum {
	my ($albums) = @_;
	
	foreach my $album (@$albums) { 
		my $albumInfo = {
			title  => $album->{title},
			id     => $album->{id},
			artist => $album->{artist},
			image  => $album->{image},
		};

		foreach my $track (@{$album->{tracks}->{items}}) {
			$track->{album} = $albumInfo;
			_precacheTrack($track);
		}		
	}
}

sub _precacheTracks {
	my ($tracks) = @_;
	
	foreach my $track (@$tracks) {
		_precacheTrack($track)
	}
}

sub _precacheTrack {
	my ($track) = @_;
	
	my $meta = {
		title    => $track->{title},
		album    => $track->{album}->{title},
		albumId  => $track->{album}->{id},
		artist   => $track->{album}->{artist}->{name},
		artistId => $track->{album}->{artist}->{id},
		cover    => $track->{album}->{image}->{large},
		duration => $track->{duration},
	};
	
	$cache->set('trackInfo_' . $track->{id}, $meta);
	
	return $meta;
}

sub _call {
	my ($url, $params) = @_;
	
	$params ||= {};
	
	my @query;
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}
	
	push @query, 'app_id=942852567';
	
	# signed requests - see
	# https://github.com/Qobuz/api-documentation#signed-requests-authentification-
	if ($params->{_sign}) {
		my $signature = $url;
		$signature =~ s/\///;
		
		$signature .= join('', sort map {
			my $v = $_;
			$v =~ s/=//;
			$v;
		} grep {
			$_ !~ /(?:app_id|user_auth_token)/
		} @query);
		
		my $ts = time;
		$signature = md5_hex($signature . $ts . '761730d3f95e4af09ac63b9a37ccc96a');
		
		push @query, "request_ts=$ts", "request_sig=$signature";
		
		$params->{_nocache} = 1; 
	}
	
	$url = BASE_URL . $url . '?' . join('&', @query);
	
	main::DEBUGLOG && $log->debug($url);
	
	if (!$params->{_nocache} && (my $cached = $cache->get($url))) {
		main::DEBUGLOG && $log->debug("getting cached value");
		return $cached;
	}
	
	my $response = $ua->get($url);
	
#	main::DEBUGLOG && warn Data::Dump::dump($response);

	if ($response->is_error) {
		my $code = $response->code;
		my $message = $response->message;
		$log->error("request failed: $code  $message");
		$params->{_nocache} = 1;
	}

	my $result = eval { from_json( $response->content ) };
	main::DEBUGLOG && warn Data::Dump::dump($result);

	if (!$params->{_nocache}) {
		$cache->set($url, $result, $params->{_ttl});
	}

	return $result;
}

1;