package Plugins::Qobuz::API;

use strict;

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API::Common;

use constant URL_EXPIRY => 60 * 10;       # Streaming URLs are short lived

# bump the second parameter if you decide to change the schema of cached data
my $cache = Plugins::Qobuz::API::Common->getCache();
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

# corrupt cache file can lead to hammering the backend with login attempts.
# Keep session information in memory, don't rely on disk cache.
my $memcache = Plugins::Qobuz::MemCache->new();

my ($aid, $as);

sub init {
	my $class = shift;
	($aid, $as) = Plugins::Qobuz::API::Common->init(@_);

	# try to get a token if needed - pass empty callback to make it look it up anyway
	$class->getToken(sub {}, !Plugins::Qobuz::API::Common->getCredentials);
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

		main::INFOLOG && $log->is_info && !$log->is_info && $log->info(Data::Dump::dump($result));

		my $token;
		if ( ! ($result && ($token = $result->{user_auth_token})) ) {
			$log->warn('Failed to get token');
			# set failure flag to prevent looping
			$memcache->set('getTokenFailed', 1, 10);
			$cb->() if $cb;
			return;
		}

		$memcache->set('token_' . $username . $password, $token, QOBUZ_DEFAULT_EXPIRY);
		# keep the user data around longer than the token
		$cache->set('userdata', $result->{user}, time() + QOBUZ_DEFAULT_EXPIRY*2);

		$cb->($token) if $cb;
	},{
		username => $username,
		password => $password,
		device_manufacturer_id => preferences('server')->get('server_uuid'),
		_nocache => 1,
	});

	return;
}

sub search {
	my ($class, $cb, $search, $type, $args) = @_;

	$args ||= {};

	$search = lc($search);

	main::DEBUGLOG && $log->debug('Search : ' . $search);

	my $key = "search_${search}_${type}_" . ($args->{_dontPreCache} || 0);

	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	$args->{limit} ||= QOBUZ_DEFAULT_LIMIT;
	$args->{_ttl}  ||= QOBUZ_EDITORIAL_EXPIRY;
	$args->{query} ||= $search;
	$args->{type}  ||= $type if $type && $type =~ /(?:albums|artists|tracks|playlists)/;

	_get('catalog/search', sub {
		my $results = shift;

		if ( !$args->{_dontPreCache} ) {
			_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

			$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

			$results->{tracks}->{items} = _precacheTracks($results->{tracks}->{items}) if $results->{tracks}->{items};
		}

		$cache->set($key, $results, 300);

		$cb->($results);
	}, $args);
}

sub getArtist {
	my ($class, $cb, $artistId) = @_;

	_get('artist/get', sub {
		my $results = shift;

		if ( $results && (my $images = $results->{image}) ) {
			my $pic = Plugins::Qobuz::API::Common->getImageFromImagesHash($images);
			_precacheArtistPictures([
				{ id => $artistId, picture => $pic }
			]) if $pic;
		}

		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

		$cb->($results) if $cb;
	}, {
		artist_id => $artistId,
		extra     => 'albums',
		limit     => QOBUZ_DEFAULT_LIMIT,
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
		_ttl  => QOBUZ_EDITORIAL_EXPIRY,
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
		limit    => QOBUZ_DEFAULT_LIMIT,
		_ttl     => QOBUZ_EDITORIAL_EXPIRY,
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
		limit    => QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
	});
}

sub getUserPurchasesIds {
	my ($class, $cb) = @_;

	_get('purchase/getUserPurchasesIds', sub {
		$cb->(@_) if $cb;
	},{
		_use_token => 1,
	})
}

sub checkPurchase {
	my ($class, $type, $id, $cb) = @_;

	$class->getUserPurchasesIds(sub {
		my ($purchases) = @_;

		$type = $type . 's';

		if ( $purchases && ref $purchases && $purchases->{$type} && ref $purchases->{$type} && (my $items = $purchases->{$type}->{items}) ) {
			if ( $items && ref $items && scalar @$items ) {
				$cb->(
					(grep { $_->{id} =~ /^\Q$id\E$/i } @$items)
					? 1
					: 0
				);
				return;
			}
		}

		$cb->();
	});
}

sub getUserFavorites {
	my ($class, $cb, $force) = @_;

	_pagingGet('favorite/getUserFavorites', sub {
		my ($favorites) = @_;

		$favorites->{albums}->{items} = _precacheAlbum($favorites->{albums}->{items}) if $favorites->{albums};
		$favorites->{tracks}->{items} = _precacheTracks($favorites->{tracks}->{items}) if $favorites->{tracks};

		$cb->($favorites);
	},{
		limit      => QOBUZ_USERDATA_LIMIT,
		_extractor => sub {
			my ($favorites) = @_;
			my $collectedFavorites;

			map {
				my $offset = $_;
				if ($collectedFavorites) {
					foreach my $category (qw(albums artists tracks)) {
						push @{$collectedFavorites->{$category}->{items}}, @{$favorites->{$offset}->{$category}->{items}};
					}
				}
				else {
					$collectedFavorites = $favorites->{$offset};
				}
			} sort {
				$a <=> $b
			} keys %$favorites;

			return $collectedFavorites;
		},
		_maxKey   => sub {
			my ($favorites) = @_;
			return max($favorites->{albums}->{total}, $favorites->{artists}->{total}, $favorites->{tracks}->{total});
		},
		_ttl       => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
		_wipecache => $force,
	});
}

sub myAlbumsMeta {
	my ($class, $cb, $noPurchases) = @_;

	_get('favorite/getUserFavorites', sub {
		my ($results) = @_;

		my $libraryMeta = {};
		if ($results && ref $results && $results->{albums} && ref $results->{albums}) {
			$libraryMeta = {
				total => $results->{albums}->{total} || 0,
				lastAdded => $results->{albums}->{items}->[0]->{favorited_at} || ''
			};
		}

		if ($noPurchases) {
			$cb->($libraryMeta);
		}
		else {
			$class->getUserPurchases(sub {
				my ($purchases) = @_;

				if ($purchases && ref $purchases && $purchases->{albums}) {
					my @timestamps = map { $_->{purchased_at} } @{ $purchases->{albums}->{items} };
					$libraryMeta->{lastAdded} = max($libraryMeta->{lastAdded}, @timestamps);
					$libraryMeta->{total} += $purchases->{albums}->{total};
				}

				$cb->($libraryMeta);
			});
		}
	}, {
		limit => 1,
		type => 'albums',
		limit => 1,
		_use_token => 1,
		_nocache => 1
	})
}

sub myArtistsMeta {
	my ($class, $cb) = @_;

	_get('favorite/getUserFavorites', sub {
		my ($results) = @_;

		my $libraryMeta = {};
		if ($results && ref $results && $results->{artists} && ref $results->{artists}) {
			$libraryMeta = {
				total => $results->{artists}->{total} || 0,
				lastAdded => $results->{artists}->{items}->[0]->{favorited_at} || ''
			};
		}

		$cb->($libraryMeta);
	}, {
		limit => 1,
		type => 'artists',
		limit => 1,
		_use_token => 1,
		_nocache => 1
	})
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
		username => $user || Plugins::Qobuz::API::Common->username,
		limit    => QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
	});
}

sub getPublicPlaylists {
	my ($class, $cb, $type, $genreId, $tags) = @_;

	my $args = {
		type  => $type =~ /(?:last-created|editor-picks)/ ? $type : 'editor-picks',
		limit => 100,		# for whatever reason this query doesn't accept more than 100 results
		_ttl  => QOBUZ_EDITORIAL_EXPIRY,
	};

	$args->{genre_ids} = $genreId if $genreId;
	$args->{tags} = $tags if $tags;

	_get('playlist/getFeatured', $cb, $args);
}

sub getPlaylistTracks {
	my ($class, $cb, $playlistId) = @_;

	_pagingGet('playlist/get', sub {
		my $tracks = shift;

		$tracks->{tracks}->{items} = _precacheTracks($tracks->{tracks}->{items});

		$cb->($tracks);
	},{
		playlist_id => $playlistId,
		extra       => 'tracks',
		limit       => QOBUZ_USERDATA_LIMIT,
		_extractor  => 'tracks',
		_maxKey     => sub {
			my ($results) = @_;
			$results->{tracks_count};
		},
		_ttl        => QOBUZ_USER_DATA_EXPIRY,
		_use_token  => 1,
	});
}

sub getTags {
	my ($class, $cb) = @_;

	_get('playlist/getTags', sub {
		my $result = shift;

		my $tags = [];

		if ($result && ref $result && $result->{tags} && ref $result->{tags}) {
			$tags = [ grep {
				$_->{id} && $_->{name};
			} map {
				my $name = eval { from_json($_->{name_json}) };
				{
					featured_tag_id => $_->{featured_tag_id},
					id => $_->{slug},
					name => $name
				};
			} @{$result->{tags}} ];
		}

		$cb->($tags);
	},{
		_use_token => 1
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
		my $meta = shift || { id => $trackId };

		$meta = precacheTrack($meta);

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
		if ($preferredFormat < QOBUZ_STREAMING_FLAC_HIRES) {
			$preferredFormat = QOBUZ_STREAMING_FLAC;
		}
		elsif ($preferredFormat > QOBUZ_STREAMING_FLAC_HIRES) {
			$preferredFormat = QOBUZ_STREAMING_FLAC_HIRES2;
		}
	}
	elsif ($format =~ /mp3/i) {
		$preferredFormat = QOBUZ_STREAMING_MP3 ;
	}

	$preferredFormat ||= $prefs->get('preferredFormat') || QOBUZ_STREAMING_MP3;

	if ( my $cached = $class->getCachedFileInfo($trackId, $urlOnly, $preferredFormat) ) {
		$cb->($cached);
		return $cached
	}

	_get('track/getFileUrl', sub {
		my $track = shift;

		if ($track) {
			my $url = delete $track->{url};

			# cache urls for a short time only
			$cache->set("trackUrl_${trackId}_${preferredFormat}", $url, URL_EXPIRY);
			$cache->set("trackId_$url", $trackId, QOBUZ_DEFAULT_EXPIRY);
			$cache->set("fileInfo_${trackId}_${preferredFormat}", $track, QOBUZ_DEFAULT_EXPIRY);
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
	my ($class, $trackId, $urlOnly, $preferredFormat) = @_;

	$preferredFormat ||= $prefs->get('preferredFormat');

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	return $cache->get($urlOnly ? "trackUrl_${trackId}_$preferredFormat" : "fileInfo_${trackId}_$preferredFormat");
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

	$url = QOBUZ_BASE_URL . $url . '?' . join('&', sort @query);

	if (main::INFOLOG && $log->is_info) {
		my $data = $url;
		$data =~ s/(?:$aid|$token)//g;
		$log->info($data);
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
				$cache->set($url, $result, $params->{_ttl} || QOBUZ_DEFAULT_EXPIRY);
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

sub _pagingGet {
	my ( $url, $cb, $params ) = @_;

	my $limit = $params->{limit};
	$params->{limit} = min($params->{limit}, QOBUZ_LIMIT);

	my $getMaxFn = ref $params->{_maxKey} ? delete $params->{_maxKey} : sub {
		my ($results) = @_;
		# warn Data::Dump::dump($results);
		# warn $params->{_maxKey};
		# warn $results->{$params->{_maxKey}};
		$results->{$params->{_maxKey}}->{total};
	};

	my $extractorFn = ref $params->{_extractor} ? delete $params->{_extractor} : sub {
		my ($results) = @_;
		my $extractor = $params->{_extractor};

		my $collector;
		map {
			if ($collector) {
				push @{$collector->{$extractor}->{items}}, @{$results->{$_}->{$extractor}->{items}};
			}
			else {
				$collector = $results->{$_};
			}
		} sort {
			$a <=> $b
		} keys %$results;

		return $collector;
	};

	_get($url, sub {
		my ($result) = @_;

		my $total = $getMaxFn->($result) || QOBUZ_LIMIT;

		main::INFOLOG && $log->is_info && $log->info("Need another page? " . Data::Dump::dump({
			total => $total,
			pageSize => $params->{limit},
			requested => $limit
		}));

		if ($total > $params->{limit} && $limit > $params->{limit}) {
			my $chunks = {};

			for (my $offset = $params->{limit}; $offset <= min($total, $limit); $offset += $params->{limit}) {
				my $params2 = Storable::dclone($params);
				$params2->{offset} = $offset;

				$chunks->{$offset} = $params2;
			}

			my $results = {
				0 => $result
			};

			while (my ($id, $params) = each %$chunks) {
				_get($url, sub {
					$results->{$id} = shift;
					delete $chunks->{$id};

					if (!scalar keys %$chunks) {
						$cb->($extractorFn->($results));
					}
				}, $params);
			}
		}
		else {
			$cb->($extractorFn->({ 0 => $result }));
		}
	}, $params);
}

sub cache { wantarray ? ($cache, $memcache) : $cache }
sub aid { $aid }

1;

# very simple memory caching class
package Plugins::Qobuz::MemCache;

use Digest::MD5 qw(md5_hex);

sub new {
	return bless {}, shift;
}

sub set {
	my ($class, $key, $value, $timeout) = @_;

	$timeout ||= Plugins::Qobuz::API::QOBUZ_DEFAULT_EXPIRY;

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
