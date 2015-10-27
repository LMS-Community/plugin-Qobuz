package Plugins::Qobuz::API;

use strict;
use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);

use constant BASE_URL => 'http://www.qobuz.com/api.json/0.2/';

use constant DEFAULT_EXPIRY   => 86400 * 30;
use constant EDITORIAL_EXPIRY => 60 * 60;       # editorial content like recommendations, new releases etc.
use constant URL_EXPIRY       => 60 * 10;       # Streaming URLs are short lived
use constant USER_DATA_EXPIRY => 60;            # user want to see changes in purchases, playlists etc. ASAP

use constant DEFAULT_LIMIT  => 200;
use constant USERDATA_LIMIT => 500;				# users know how many results to expect - let's be a bit more generous :-)

use constant STREAMING_MP3  => 5;
use constant STREAMING_FLAC => 6;
use constant STREAMING_FLAC_HIRES => 27;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# bump the second parameter if you decide to change the schema of cached data
my $cache = Slim::Utils::Cache->new('qobuz', 6);
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

# corrupt cache file can lead to hammering the backend with login attempts.
# Keep session information in memory, don't rely on disk cache.
my $memcache = Plugins::Qobuz::MemCache->new();

my $fastdistance;

eval {
	require Text::LevenshteinXS;
	$fastdistance = sub { Text::LevenshteinXS::distance(@_); };
	# let the user know we've been able to load the XS module - can silence this later
	$log->error('Success: using Text::LevenshteinXS to speed Qobuz up.');
};

if ($@) {
	$log->info('Failed to load Text::LevenshteinXS module: ' . $@);
} 

eval {
	require Text::Levenshtein;
	$fastdistance = sub { Text::Levenshtein::fastdistance(@_); };
} unless $fastdistance;

$fastdistance ||= sub { 0 };

if ($@) {
	$log->error('Failed to load Text::Levenshtein module: ' . $@);
} 

my ($aid, $as);

sub init {
	my $class = shift;
	($aid, $as) = pack('H*', $_[0]) =~ /^(\d{9})(.*)/;
	
	# try to get a token if needed - pass empty callback to make it look it up anyway
	$class->getToken(sub {}, !$cache->get('credential'));
}

sub getToken {
	my ($class, $cb, $force) = @_;
	
	my $username = $prefs->get('username');
	my $password = $prefs->get('password_md5_hash');
	
	if ( !($username && $password) || $memcache->get('getTokenFailed') ) {
		$cb->() if $cb;
		return;
	}

	if ( !$force && ( (my $token = $memcache->get('token_' . $username . $password)) || !$cb ) ) {
		$cb->($token) if $cb;
		return $token;
	}
	
	if ( ($memcache->get('login') || 0) > 5 ) {
		$log->error("Something's wrong: logging in in too short intervals. We're going to pause for a while as to not get blocked by the backend.");
		$memcache->set('getTokenFailed', 30);

		$cb->() if $cb;
		return;
	}
	
	# Set a timestamp we're going to use to prevent repeated logins. 
	# Don't allow more than one login attempt per x seconds.
	my $attempts = $memcache->get('login') || 0;
	$memcache->set('login', $attempts++, 5);
	
	_get('user/login', sub {
		my $result = shift;
	
		my $token;
		if ( ! ($result && ($token = $result->{user_auth_token})) ) {
			# set failure flag to prevent looping
			$memcache->set('getTokenFailed', 1, 10);
			$cb->() if $cb;
			return;
		}
	
		$cache->set('username', $result->{user}->{login} || $username, DEFAULT_EXPIRY) if $result->{user};
		$memcache->set('token_' . $username . $password, $token, DEFAULT_EXPIRY);
		$cache->set('credential', $result->{user}->{credential}->{label}, DEFAULT_EXPIRY) if $result->{user} && $result->{user}->{credential};
	
		$cb->($token) if $cb;
	},{
		username => $username,
		password => $password,
		_nocache => 1,
	});
	
	return;
}

sub getCredentials {
	return $cache->get('credential');
}

sub username {
	return $cache->get('username') || $prefs->get('username');
}

sub search {
	my ($class, $cb, $search, $type, $limit, $filter) = @_;
	
	$search = lc($search);
	
	main::DEBUGLOG && $log->debug('Search : ' . $search);
	
	$filter = ($prefs->get('filterSearchResults') || 0) unless defined $filter;
	my $key = "search_${search}_${type}_$filter";
	
	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	my $args = {
		query => $search, 
		limit => $limit || DEFAULT_LIMIT,
		_ttl  => EDITORIAL_EXPIRY,
	};
	
	$args->{type} = $type if $type && $type =~ /(?:albums|artists|tracks|playlists)/;

	_get('catalog/search', sub {
		my $results = shift;
		
		if ( $filter && $results->{artists}->{items} ) {
			my %seen;
			
			# filter out duplicates etc.
			$results->{artists}->{items} = [ grep {
				!($seen{lc($_->{name})}++ && !$_->{album_count})
			} sort { 
				# sort tracks by popularity if the name is identical
				if ($a->{sortName} eq $b->{sortName} && defined $a->{album_count} && defined $b->{album_count}) {
					return $b->{album_count} <=> $a->{album_count};
				}
				
				return $fastdistance->($search, $a->{sortName}) <=> $fastdistance->($search, $b->{sortName});
			} map {
				$_->{sortName} = lc($_->{name});
				$_;
			} grep {
				$_->{name} =~ /\Q$search\E/i;
			} @{$results->{artists}->{items}} ];
		}
		
		_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};
		
		if ( $filter && $results->{albums}->{items} ) {
			$results->{albums}->{items} = [ sort { 
				$fastdistance->($search, $a->{sortTitle}) <=> $fastdistance->($search, $b->{sortTitle}) 
			} map {
				# lower case and remove any trailing "Remix" etc.
				$_->{sortTitle} = lc($_->{title});
				$_->{sortTitle} =~ s/ [(\[][^(\[]*[)\]]$//;
				$_;
			} grep {
				$_->{title} =~ /\Q$search\E/i || ($_->{artist} && (lc($_->{artist}->{name}) || '') eq $search)
			} @{$results->{albums}->{items}} ];
		}
		
		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};
		
		if ( $filter && $results->{tracks}->{items} ) {
			$results->{tracks}->{items} = [ sort { 
				# sort tracks by popularity if the name is identical
				if ($a->{sortTitle} eq $b->{sortTitle} && $a->{album} && $b->{album}) {
					return _weightedPopularity($b->{album}) <=> _weightedPopularity($a->{album});
				}
				
				return $fastdistance->($search, $a->{sortTitle}) <=> $fastdistance->($search, $b->{sortTitle});
			} map {
				# lower case and remove any trailing "Remix" etc.
				$_->{sortTitle} = lc($_->{title});
				$_->{sortTitle} =~ s/ [(\[][^(\[]*[)\]]$// if $_->{sortTitle} !~ /(?:mix|rmx|edit|karaoke)/i;
				$_;
			} grep {
				$_->{title} =~ /\Q$search\E/i;
			} @{$results->{tracks}->{items}} ];
		}

		$results->{tracks}->{items} = _precacheTracks($results->{tracks}->{items}) if $results->{tracks}->{items};
		
		$cache->set($key, $results, 300);
		
		$cb->($results);
	}, $args);
}

sub _weightedPopularity {
	my ($album) = @_;
	
	my $popularity = $album->{popularity};
	$popularity *= 0.90 if $album->{title} =~ /(?:mix|rmx|edit|karaoke|originally)/i;
	$popularity *= 0.90 if $album->{title} =~ /(?:made famous)/i;
	$popularity *= 0.90 if $album->{genre}->{slug} =~ /(?:electro|lounge|disco|dance|techno)/i;
	$popularity *= 0.80 if $album->{genre}->{slug} =~ /(?:series|divers|bandes-origininales|soundtrack)/i;
	$popularity *= 0.95 if $album->{tracks_count} >= 20;
	$popularity *= 0.95 if $album->{tracks_count} >= 40;
	$popularity *= 0.95 if $album->{title} =~ /vol.*\d/;
	$popularity *= 0.80 if $album->{label}->{albums_count} > 500;
	$popularity *= 0.60 if $album->{label}->{albums_count} > 1000;
	$popularity *= 0.80 if $album->{artist}->{slug} =~ /(?:various|divers)/i;
	
	return $popularity;
}

sub getArtist {
	my ($class, $cb, $artistId) = @_;
	
	_get('artist/get', sub {
		my $results = shift;
		
		if ( $results && (my $images = $results->{image}) ) {
			my $pic = $images->{mega} || $images->{extralarge} || $images->{large} || $images->{large} || $images->{medium} || $images->{small};
			_precacheArtistPictures([
				{ id => $artistId, picture => $pic }
			]) if $pic;
		}
		
		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};
		
		$cb->($results) if $cb;
	}, {
		artist_id => $artistId,
		extra     => 'albums',
		limit     => DEFAULT_LIMIT,
	});
}

sub getArtistPicture {
	my ($class, $artistId) = @_;
	
	my $url = $cache->get('artistpicture_' . $artistId) || '';

	_precacheArtistPictures([{ id => $artistId }]) unless $url;
	
	return $url;
}

sub getSimilarArtists {
	my ($class, $cb, $artistId) = @_;
	
	_get('artist/getSimilarArtists', sub {
		my $results = shift;
		
		_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};
		
		$cb->($results);
	}, {
		artist_id => $artistId,
		limit     => 100,	# max. is 100
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
	
		($album) = @{_precacheAlbum([$album])} if $album;
		
		$cb->($album);
	},{
		album_id => $albumId,
	});
}

sub getFeaturedAlbums {
	my ($class, $cb, $type, $genreId) = @_;
	
	my $args = {
		type     => $type,
		limit    => DEFAULT_LIMIT,
		_ttl     => EDITORIAL_EXPIRY,
	};
	
	$args->{genre_id} = $genreId if $genreId;
	
	_get('album/getFeatured', sub {
		my $albums = shift;
	
		$albums->{albums}->{items} = _precacheAlbum($albums->{albums}->{items}) if $albums->{albums};
		
		$cb->($albums);
	}, $args);
}

sub getUserPurchases {
	my ($class, $cb) = @_;
	
	_get('purchase/getUserPurchases', sub {
		my $purchases = shift; 
		
		$purchases->{albums}->{items} = _precacheAlbum($purchases->{albums}->{items}) if $purchases->{albums};
		$purchases->{tracks}->{items} = _precacheTracks($purchases->{tracks}->{items}) if $purchases->{tracks};
		
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
		
		$favorites->{albums}->{items} = _precacheAlbum($favorites->{albums}->{items}) if $favorites->{albums};
		$favorites->{tracks}->{items} = _precacheTracks($favorites->{tracks}->{items}) if $favorites->{tracks};
		
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
	
	_get('playlist/getUserPlaylists', sub {
		my $playlists = shift;
		
		$playlists->{playlists}->{items} = [ sort { 
			lc($a->{name}) cmp lc($b->{name}) 
		} @{$playlists->{playlists}->{items}} ];
		
		$cb->($playlists);
	}, {
		username => $user || __PACKAGE__->username,
		limit    => USERDATA_LIMIT,
		_ttl     => USER_DATA_EXPIRY,
		_use_token => 1,
	});
}

sub getPublicPlaylists {
	my ($class, $cb, $type, $genreId) = @_;

	my $args = {
		type  => $type =~ /(?:last-created|editor-picks)/ ? $type : 'editor-picks',
		limit => 100,		# for whatever reason this query doesn't accept more than 100 results
		_ttl  => EDITORIAL_EXPIRY,
	};
	
	$args->{genre_ids} = $genreId if $genreId;
	
	_get('playlist/getFeatured', $cb, $args);
}

sub getPlaylistTracks {
	my ($class, $cb, $playlistId) = @_;

	_get('playlist/get', sub {
		my $tracks = shift;
		
		$tracks->{tracks}->{items} = _precacheTracks($tracks->{tracks}->{items});
		
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
	my ($class, $cb, $trackId, $format) = @_;
	$class->getFileInfo($cb, $trackId, $format, 'url');
}

sub getFileInfo {
	my ($class, $cb, $trackId, $format, $urlOnly) = @_;

	$cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}
	
	my $preferredFormat;
	
	if ($format =~ /fl.c/i) {
		$preferredFormat = $prefs->get('preferredFormat');
		$preferredFormat = STREAMING_FLAC if $preferredFormat < STREAMING_FLAC_HIRES;
	}

	$preferredFormat = STREAMING_MP3 if $format =~ /mp3/i;
	$preferredFormat ||= $prefs->get('preferredFormat') || STREAMING_MP3;
	
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

# figure out what streaming format we can use
# - check preference
# - fall back to mp3 samples if not streamable
# - check user's subscription level
sub getStreamingFormat {
	my ($class, $track) = @_;
	
	# shortcut if user prefers mp3 over flac anyway
	return 'mp3' unless $prefs->get('preferredFormat') >= STREAMING_FLAC;
	
	my $ext = 'flac';

	my $credential = $class->getCredentials;
	if (!$credential || $credential !~ /streaming-(?:lossless|classique|hifi-sublime)/ ) {
		$ext = 'mp3';
	}
	elsif ($track && ref $track eq 'HASH') {
		$ext = 'mp3' unless $track->{streamable};
	}
	
	return $ext;
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
	
	return unless $albums && ref $albums eq 'ARRAY';
	
	my $t = time;
	$albums = [ grep {
		($_->{released_at} ? $_->{released_at} <= $t : 1) && $_->{streamable};
	} @$albums ] unless $prefs->get('playSamples');
	
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
	
	return $albums;
}

my @artistsToLookUp;
my $artistLookup;
sub _precacheArtistPictures {
	my ($artists) = @_;
	
	return unless $artists && ref $artists eq 'ARRAY';
	
	foreach my $artist (@$artists) {
		my $key = 'artistpicture_' . $artist->{id};
		if ($artist->{picture}) {
			$cache->set($key, $artist->{picture}, -1);
		}
		elsif (!$cache->get($key)) {
			push @artistsToLookUp, $artist->{id};
		}
	}
	
	_lookupArtistPicture() if @artistsToLookUp && !$artistLookup;
}

sub _lookupArtistPicture {
	if ( !scalar @artistsToLookUp ) {
		$artistLookup = 0;
	}
	else {
		$artistLookup = 1;
		__PACKAGE__->getArtist(\&_lookupArtistPicture, shift @artistsToLookUp);
	}
}

sub _precacheTracks {
	my ($tracks) = @_;
	
	return unless $tracks && ref $tracks eq 'ARRAY';
	
	my $t = time;
	$tracks = [ grep {
		($_->{released_at} ? $_->{released_at} <= $t : 1) && $_->{streamable};
	} @$tracks ] unless $prefs->get('playSamples');

	foreach my $track (@$tracks) {
		_precacheTrack($track)
	}
	
	return $tracks;
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
			if ( $prefs->get('username') && $prefs->get('password_md5_hash') && !$memcache->get('getTokenFailed') ) {
				__PACKAGE__->getToken(sub {
					# we'll get back later to finish the original call...
					_get($url, $cb, $params)
				});
			}
			else {
				$log->error('No or invalid username/password available') unless $prefs->get('username') && $prefs->get('password_md5_hash');
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
		main::DEBUGLOG && $log->is_debug && $log->debug("found cached response: " . Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			
			my $result = eval { from_json($response->content) };
				
			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $url !~ /getFileUrl/i && $log->debug(Data::Dump::dump($result));
			
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

# very simple memory caching class
package Plugins::Qobuz::MemCache;

use Digest::MD5 qw(md5_hex);

sub new {
	return bless {}, shift;
}

sub set {
	my ($class, $key, $value, $timeout) = @_;
	
	$timeout ||= Plugins::Qobuz::API::DEFAULT_EXPIRY;
	
	$class->{md5_hex($key)} = {
		v => $value,
		t => Time::HiRes::time() + $timeout,
	};
}

sub get {
	my ($class, $key) = @_;
	
	$key = md5_hex($key);

	my $value;
	
	if (my $cached = $class->{$key}) {
		if ( $cached->{t} > Time::HiRes::time() ) {
			$value = $cached->{v};
		}
		else {
			delete $class->{$key};
		}
	}
	
	return $value;
}

1;
