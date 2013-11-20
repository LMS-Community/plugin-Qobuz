package Plugins::Qobuz::API;

use strict;
use base qw(Slim::Plugin::OPMLBased);
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);

use constant BASE_URL => 'http://www.qobuz.com/api.json/0.2/';

use constant DEFAULT_EXPIRY   => 86400 * 30;
use constant EDITORIAL_EXPIRY => 60 * 60;       # editorial content like recommendations, new releases etc.
use constant URL_EXPIRY       => 60 * 10;       # Streaming URLs are short lived
use constant USER_DATA_EXPIRY => 60 * 5;        # user want to see changes in purchases, playlists etc. ASAP

use constant DEFAULT_LIMIT  => 200;
use constant USERDATA_LIMIT => 500;				# users know how many results to expect - let's be a bit more generous :-)

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# bump the second parameter if you decide to change the schema of cached data
my $cache = Slim::Utils::Cache->new('qobuz', 5);
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my ($aid, $as);

sub init {
	my $class = shift;
	($aid, $as) = pack('H*', $_[0]) =~ /^(\d{9})(.*)/;
	
	# try to get a token if needed - pass empty callback to make it look it up anyway
	$class->getToken(sub {});
}

sub getToken {
	my ($class, $cb) = @_;
	
	my $username = $prefs->get('username');
	my $password = $prefs->get('password_md5_hash');
	
	if ( !($username && $password) ) {
		$cb->() if $cb;
		return;
	}

	if ( (my $token = $cache->get('token_' . $username . $password)) || !$cb ) {
		$cb->($token) if $cb;
		return $token;
	}
	
	_get('user/login', sub {
		my $result = shift;
	
		my $token;
		if ( ! ($result && ($token = $result->{user_auth_token})) ) {
			$cache->set('token', -1, 30);
			$cb->() if $cb;
			return;
		}
	
		$cache->set('username', $result->{user}->{login} || $username, DEFAULT_EXPIRY) if $result->{user};
		$cache->set('token_' . $username . $password, $token, DEFAULT_EXPIRY);
	
		$cb->($token) if $cb;
	},{
		username => $username,
		password => $password,
	});
	
	return;
}

sub username {
	return $cache->get('username') || $prefs->get('username');
}

sub search {
	my ($class, $cb, $search, $type) = @_;
	
	main::DEBUGLOG && $log->debug('Search : ' . $search);

	my $args = {
		query => $search, 
		limit => DEFAULT_LIMIT,
		_ttl  => EDITORIAL_EXPIRY,
	};
	
	$args->{type} = $type if $type && $type =~ /(?:albums|artists|tracks)/;

	_get('catalog/search', $cb, $args);
}

sub getArtist {
	my ($class, $cb, $artistId) = @_;
	
	_get('artist/get', $cb, {
		artist_id => $artistId
	});
}

sub getGenres {
	my ($class, $cb, $genreId) = @_;
	
	_get('genre/list', $cb, {
		parent_id => $genreId
	});
}

sub getGenre {
	my ($class, $cb, $genreId) = @_;
	
	_get('genre/get', $cb, {
		genre_id => $genreId,
		extra => 'subgenresCount,albums',
		_ttl  => EDITORIAL_EXPIRY,
	});
}

sub getAlbum {
	my ($class, $cb, $albumId) = @_;
	
	_get('album/get', sub {
		my $album = shift;
	
		_precacheAlbum([$album]) if $album;
		
		$cb->($album);
	},{
		album_id => $albumId,
	});
}

sub getFeaturedAlbums {
	my ($class, $cb, $type, $genreId) = @_;
	
	_get('album/getFeatured', sub {
		my $albums = shift;
	
		_precacheAlbum($albums->{albums}->{items}) if $albums->{albums};
		
		$cb->($albums);
	},{
		type     => $type,
		genre_id => $genreId,
		limit    => DEFAULT_LIMIT,
		_ttl     => EDITORIAL_EXPIRY,
	});
}

sub getUserPurchases {
	my ($class, $cb) = @_;
	
	_get('purchase/getUserPurchases', sub {
		my $purchases = shift; 
		
		_precacheAlbum($purchases->{albums}->{items}) if $purchases->{albums};
		_precacheTracks($purchases->{tracks}->{items}) if $purchases->{tracks};
		
		$cb->($purchases);
	},{
		limit    => USERDATA_LIMIT,
		_ttl     => USER_DATA_EXPIRY,
		_use_token => 1,
	});
}

sub getUserFavorites {
	my ($class, $cb, $force) = @_;
	
	_get('favorite/getUserFavorites', sub {
		my ($favorites) = @_; 
		
		_precacheAlbum($favorites->{albums}->{items}) if $favorites->{albums};
		_precacheTracks($favorites->{tracks}->{items}) if $favorites->{tracks};
		
		$cb->($favorites);
	},{
		limit    => USERDATA_LIMIT,
		_ttl     => USER_DATA_EXPIRY,
		_use_token => 1,
		_wipecache => $force,
	});
}

sub createFavorite {
	my ($class, $cb, $args) = @_;
	
	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;
	
	_get('favorite/create', sub {
		$cb->(shift);
		$class->getUserFavorites(sub{}, 'refresh')
	}, $args);
}

sub deleteFavorite {
	my ($class, $cb, $args) = @_;
	
	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;
	
	_get('favorite/delete', sub {
		$cb->(shift);
		$class->getUserFavorites(sub{}, 'refresh')
	}, $args);
}

sub getUserPlaylists {
	my ($class, $cb, $user) = @_;
	
	_get('playlist/getUserPlaylists', $cb, {
		username => $user || __PACKAGE__->username,
		limit    => USERDATA_LIMIT,
		_ttl     => USER_DATA_EXPIRY,
		_use_token => 1,
	});
}

sub getPublicPlaylists {
	my ($class, $cb) = @_;
	
	_get('playlist/getPublicPlaylists', $cb, {
		type  => 'last-created',
		limit => DEFAULT_LIMIT,
		_ttl  => EDITORIAL_EXPIRY,
	});
}

sub getPlaylistTracks {
	my ($class, $cb, $playlistId) = @_;

	_get('playlist/get', sub {
		my $tracks = shift;
		
		_precacheTracks($tracks->{tracks}->{items});
		
		$cb->($tracks);
	},{
		playlist_id => $playlistId,
		extra       => 'tracks',
		limit       => USERDATA_LIMIT,
		_ttl        => USER_DATA_EXPIRY,
		_use_token  => 1,
	});
}

sub getTrackInfo {
	my ($class, $cb, $trackId) = @_;

	$cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}
	
	my $meta = $cache->get('trackInfo_' . $trackId);
	
	if ($meta) {
		$cb->($meta);
		return $meta;
	}
	
	_get('track/get', sub {
		my $meta = shift;
		$meta = _precacheTrack($meta) if $meta;
		
		$cb->($meta);
	},{
		track_id => $trackId
	});
}

sub getFileUrl {
	my ($class, $cb, $trackId) = @_;
	$class->getFileInfo($cb, $trackId, 'url');
}

sub getFileInfo {
	my ($class, $cb, $trackId, $urlOnly) = @_;

	$cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}
	
	my $preferredFormat = $prefs->get('preferredFormat');
	
	if ( my $cached = $class->getCachedFileInfo($trackId, $urlOnly) ) {
		$cb->($cached);
		return $cached
	}
	
	_get('track/getFileUrl', sub {
		my $track = shift;
	
		if ($track) {
			my $url = delete $track->{url};
	
			# cache urls for a short time only
			$cache->set("trackUrl_${trackId}_$preferredFormat", $url, URL_EXPIRY);
			$cache->set("trackId_$url", $trackId, DEFAULT_EXPIRY);
			$cache->set("fileInfo_${trackId}_$preferredFormat", $track, DEFAULT_EXPIRY);
			$track = $url if $urlOnly;
		}
		
		$cb->($track);
	},{
		track_id   => $trackId,
		format_id  => $preferredFormat,
		_ttl       => URL_EXPIRY,
		_sign      => 1,
		_use_token => 1,
	});
}

# this call is synchronous, as it's only working on cached data
sub getCachedFileInfo {
	my ($class, $trackId, $urlOnly) = @_;

	my $preferredFormat = $prefs->get('preferredFormat');

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}
	
	return $cache->get($urlOnly ? "trackUrl_${trackId}_$preferredFormat" : "fileInfo_${trackId}_$preferredFormat");
}

sub _precacheAlbum {
	my ($albums) = @_;
	
	foreach my $album (@$albums) { 
		my $albumInfo = {
			title  => $album->{title},
			id     => $album->{id},
			artist => $album->{artist},
			image  => $album->{image},
			year   => (localtime($album->{released_at}))[5] + 1900,
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
	
	my $album = $track->{album};
	
	my $meta = {
		title    => $track->{title},
		album    => $album->{title},
		albumId  => $album->{id},
		artist   => $album->{artist}->{name},
		artistId => $album->{artist}->{id},
		cover    => $album->{image}->{large},
		duration => $track->{duration},
		year     => $album->{year} || (localtime($album->{released_at}))[5] + 1900,
	};
	
	$cache->set('trackInfo_' . $track->{id}, $meta, DEFAULT_EXPIRY);
	
	return $meta;
}

sub _get {
	my ( $url, $cb, $params ) = @_;
	
	# need to get a token first?
	my $token = '';
	
	if ($url ne 'user/login') {
		$token = __PACKAGE__->getToken();
		if ( !$token ) {
			if ( $prefs->get('username') && $prefs->get('password_md5_hash') ) {
				__PACKAGE__->getToken(sub {
					# we'll get back later to finish the original call...
					_get($url, $cb, $params)
				});
			}
			else {
				$log->error('No or invalid username/password available');
				$cb->();
			}
			return;
		}
	}

	$params->{user_auth_token} = $token if delete $params->{_use_token};
	
	$params ||= {};
	
	my @query;
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}
	
	push @query, "app_id=$aid";
	
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
		$signature = md5_hex($signature . $ts . $as);
		
		push @query, "request_ts=$ts", "request_sig=$signature";
		
		$params->{_nocache} = 1; 
	}
	
	$url = BASE_URL . $url . '?' . join('&', sort @query);
	
	if (main::DEBUGLOG && $log->is_debug) {
		my $data = $url;
		$data =~ s/(?:$aid|$token)//g;
		$log->debug($data);
	}
	
	if ($params->{_wipecache}) {
		$cache->remove($url);
	}
	
	if (!$params->{_nocache} && (my $cached = $cache->get($url))) {
		main::DEBUGLOG && $log->debug("found cached response: " . Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			
			my $result = eval { from_json($response->content) };
				
			$@ && $log->error($@);
			main::DEBUGLOG && $log->debug(Data::Dump::dump($result));
			
			if ($result && !$params->{_nocache}) {
				$cache->set($url, $result, $params->{_ttl} || DEFAULT_EXPIRY);
			}

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;
			
			# login failed due to invalid username/password: delete password
			if ($error =~ /^401/ && $http->url =~ m|user/login|i) {
				$prefs->remove('password_md5_hash');
			}

			$log->warn("Error: $error");
			$cb->();
		},
		{
			timeout => 15,
		},
	)->get($url, 'X-User-Auth-Token' => $token, 'X-App-Id' => $aid);
}

1;
