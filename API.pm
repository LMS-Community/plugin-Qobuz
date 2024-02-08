package Plugins::Qobuz::API;

use strict;
use base qw(Slim::Utils::Accessor);

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API::Common;

use constant URL_EXPIRY => 60 * 10;       # Streaming URLs are short lived
use constant BROWSER_UA => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15';

# bump the second parameter if you decide to change the schema of cached data
my $cache = Plugins::Qobuz::API::Common->getCache();
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my %apiClients;

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
	) );
}

sub new {
	my ($class, $args) = @_;

	if (!$args->{client} && !$args->{userId}) {
		return;
	}

	my $client = $args->{client};
	my $userId = $args->{userId} || $prefs->client($client)->get('userId') || return;

	if (my $apiClient = $apiClients{$userId}) {
		return $apiClient;
	}

	my $self = $apiClients{$userId} = $class->SUPER::new();
	$self->client($client);
	$self->userId($userId);

	# update our profile ASAP
	$self->updateUserdata();

	return $self;
}

my ($aid, $as, $cid);

sub init {
	($aid, $as, $cid) = Plugins::Qobuz::API::Common->init(@_);
}

sub login {
	my ($class, $username, $password, $cb, $args) = @_;

	if ( !($username && $password) ) {
		$cb->() if $cb;
		return;
	}

	my $params = {
		username => $username,
		password => $password,
		device_manufacturer_id => preferences('server')->get('server_uuid'),
		_nocache => 1,
		_cid     => $args->{cid} ? 1 : 0,
	};

	$class->_get('user/login', sub {
		my $result = shift;

		main::INFOLOG && $log->is_info && !$log->is_info && $log->info(Data::Dump::dump($result));

		my ($token, $user_id);
		if ( ! ($result && ($token = $result->{user_auth_token}) && $result->{user} && ($user_id = $result->{user}->{id})) ) {
			$log->warn('Failed to get token');
			$cb->() if $cb;
			return;
		}

		my $accounts = $prefs->get('accounts') || {};

		if (!$args || !$args->{cid}) {
			$accounts->{$user_id}->{token} = $token;
			$accounts->{$user_id}->{userdata} = $result->{user};

			$class->login($username, $password, sub {
				$cb->(@_) if $cb;
			}, {
				cid => 1,
				token => $token,
			});
		}
		else {
			$accounts->{$user_id}->{webToken} = $token;
			$cb->($args->{token}) if $cb;
		}

		$prefs->set('accounts', $accounts);
	}, $params);
}

sub updateUserdata {
	my ($self, $cb) = @_;

	$self->_get('user/get', sub {
		my $result = shift;

		if ($result && ref $result eq 'HASH') {
			my $userdata = Plugins::Qobuz::API::Common->getUserdata($self->userId);

			foreach my $k (keys %$result) {
				$userdata->{$k} = $result->{$k} if defined $result->{$k};
			}

			$prefs->save();
		}

		$cb->($result) if $cb;
	},{
		user_id => $self->userId,
		_nocache => 1,
	})
}

sub getMyWeekly {
	my ($self, $cb) = @_;

	$self->_get('dynamic-tracks/get', sub {
		my $myWeekly = shift;

		$myWeekly->{tracks}->{items} = _precacheTracks($myWeekly->{tracks}->{items} || []) if $myWeekly->{tracks};

		$cb->($myWeekly);
	}, {
		type        => 'weekly',
		limit       => 50,
		offset      => 0,
		_ttl        => 60 * 60 * 12,
		_use_token  => 1,
		_cid        => 1,
	});
}

sub search {
	my ($self, $cb, $search, $type, $args) = @_;

	$args ||= {};

	$search = lc($search);

	main::INFOLOG && $log->info('Search : ' . $search);

	my $key = uri_escape_utf8("search_${search}_${type}_") . ($args->{_dontPreCache} || 0);

	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	$args->{limit} ||= QOBUZ_DEFAULT_LIMIT;
	$args->{_ttl}  ||= QOBUZ_EDITORIAL_EXPIRY;
	$args->{query} ||= $search;
	$args->{type}  ||= $type if $type && $type =~ /(?:albums|artists|tracks|playlists)/;

	$self->_get('catalog/search', sub {
		my $results = shift;

		if ( !$args->{_dontPreCache} ) {
			$self->_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

			$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

			$results->{tracks}->{items} = _precacheTracks($results->{tracks}->{items}) if $results->{tracks}->{items};
		}

		$cache->set($key, $results, 300);

		$cb->($results);
	}, $args);
}

sub getArtist {
	my ($self, $cb, $artistId) = @_;

	$self->_get('artist/get', sub {
		my $results = shift;

		if ( $results && (my $images = $results->{image}) ) {
			my $pic = Plugins::Qobuz::API::Common->getImageFromImagesHash($images);
			$self->_precacheArtistPictures([
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

sub getLabel {
	my ($self, $cb, $labelId) = @_;

	$self->_get('label/get', sub {
		my $results = shift;

		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

		$cb->($results) if $cb;
	}, {
		label_id => $labelId,
		extra     => 'albums',
		limit     => QOBUZ_DEFAULT_LIMIT,
	});
}

sub getArtistPicture {
	my ($self, $artistId) = @_;

	my $url = $cache->get('artistpicture_' . $artistId) || '';

	$self->_precacheArtistPictures([{ id => $artistId }]) unless $url;

	return $url;
}

sub getSimilarArtists {
	my ($self, $cb, $artistId) = @_;

	$self->_get('artist/getSimilarArtists', sub {
		my $results = shift;

		$self->_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

		$cb->($results);
	}, {
		artist_id => $artistId,
		limit     => 100,	# max. is 100
	});
}

sub getGenres {
	my ($self, $cb, $genreId) = @_;

	my $params = {};
	$params->{parent_id} = $genreId if $genreId;

	$self->_get('genre/list', $cb, $params);
}

sub getAlbum {
	my ($self, $cb, $albumId) = @_;

	$self->_get('album/get', sub {
		my $album = shift;

		($album) = @{_precacheAlbum([$album])} if $album;

		$cb->($album);
	},{
		album_id => $albumId,
	});
}

sub getFeaturedAlbums {
	my ($self, $cb, $type, $genreId) = @_;

	my $args = {
		type     => $type,
		limit    => QOBUZ_DEFAULT_LIMIT,
		_ttl     => QOBUZ_EDITORIAL_EXPIRY,
	};

	$args->{genre_id} = $genreId if $genreId;

	$self->_get('album/getFeatured', sub {
		my $albums = shift;

		$albums->{albums}->{items} = _precacheAlbum($albums->{albums}->{items}) if $albums->{albums};

		$cb->($albums);
	}, $args);
}

sub getUserPurchases {
	my ($self, $cb, $limit) = @_;

	$self->_get('purchase/getUserPurchases', sub {
		my $purchases = shift;

		$purchases->{albums}->{items} = _precacheAlbum($purchases->{albums}->{items}) if $purchases->{albums};
		$purchases->{tracks}->{items} = _precacheTracks($purchases->{tracks}->{items}) if $purchases->{tracks};

		$cb->($purchases);
	},{
		limit    => $limit || QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	});
}

sub getUserPurchasesIds {
	my ($self, $cb) = @_;

	$self->_get('purchase/getUserPurchasesIds', sub {
		$cb->(@_) if $cb;
	},{
		_user_cache => 1,
		_use_token => 1,
	})
}

sub checkPurchase {
	my ($self, $type, $id, $cb) = @_;

	$self->getUserPurchasesIds(sub {
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
	my ($self, $cb, $force) = @_;

	$self->_pagingGet('favorite/getUserFavorites', sub {
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

sub createFavorite {
	my ($self, $cb, $args) = @_;

	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;

	$self->_get('favorite/create', sub {
		$cb->(shift);
		$self->getUserFavorites(sub{}, 'refresh')
	}, $args);
}

sub deleteFavorite {
	my ($self, $cb, $args) = @_;

	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;

	$self->_get('favorite/delete', sub {
		$cb->(shift);
		$self->getUserFavorites(sub{}, 'refresh')
	}, $args);
}

sub getUserPlaylists {
	my ($self, $cb, $user, $limit) = @_;

	$self->_get('playlist/getUserPlaylists', sub {
		my $playlists = shift;

		$playlists->{playlists}->{items} = [ sort {
			lc($a->{name}) cmp lc($b->{name})
		} @{$playlists->{playlists}->{items} || []} ] if $playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists};

		$cb->($playlists);
	}, {
		username => $user || Plugins::Qobuz::API::Common->username($self->userId),
		limit    => $limit || QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	});
}

sub getPublicPlaylists {
	my ($self, $cb, $type, $genreId, $tags) = @_;

	my $args = {
		type  => $type =~ /(?:last-created|editor-picks)/ ? $type : 'editor-picks',
		limit => 100,		# for whatever reason this query doesn't accept more than 100 results
		_ttl  => QOBUZ_EDITORIAL_EXPIRY,
	};

	$args->{genre_ids} = $genreId if $genreId;
	$args->{tags} = $tags if $tags;

	$self->_get('playlist/getFeatured', $cb, $args);
}

sub getPlaylistTracks {
	my ($self, $cb, $playlistId) = @_;

	$self->_pagingGet('playlist/get', sub {
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
	my ($self, $cb) = @_;

	$self->_get('playlist/getTags', sub {
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
	my ($self, $cb, $trackId) = @_;

	return $cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	my $meta = $cache->get('trackInfo_' . $trackId);

	if ($meta) {
		$cb->($meta);
		return $meta;
	}

	$self->_get('track/get', sub {
		my $meta = shift || { id => $trackId };

		$meta = precacheTrack($meta);

		$cb->($meta);
	},{
		track_id => $trackId
	});
}

sub getFileUrl {
	my ($self, $cb, $trackId, $format, $client) = @_;

	my $maxSupportedSamplerate = min(map {
		$_->maxSupportedSamplerate
	} grep {
		$_->maxSupportedSamplerate
	} $client->syncGroupActiveMembers);

	$self->getFileInfo($cb, $trackId, $format, 'url', $maxSupportedSamplerate);
}

sub getFileInfo {
	my ($self, $cb, $trackId, $format, $urlOnly, $maxSupportedSamplerate) = @_;

	$cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	my $preferredFormat;

	if ($format =~ /fl.c/i) {
		$preferredFormat = $prefs->get('preferredFormat');
		if ($preferredFormat < QOBUZ_STREAMING_FLAC_HIRES || ($maxSupportedSamplerate && $maxSupportedSamplerate < 48_000)) {
			$preferredFormat = QOBUZ_STREAMING_FLAC;
		}
		elsif ($preferredFormat > QOBUZ_STREAMING_FLAC_HIRES) {
			if ($maxSupportedSamplerate && $maxSupportedSamplerate <= 96_000) {
				$preferredFormat = QOBUZ_STREAMING_FLAC_HIRES;
			}
		}
	}
	elsif ($format =~ /mp3/i) {
		$preferredFormat = QOBUZ_STREAMING_MP3 ;
	}

	$preferredFormat ||= $prefs->get('preferredFormat') || QOBUZ_STREAMING_MP3;

	if ( my $cached = $self->getCachedFileInfo($trackId, $urlOnly, $preferredFormat) ) {
		$cb->($cached);
		return $cached
	}

	$self->_get('track/getFileUrl', sub {
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
	my ($self, $artists) = @_;

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

	$self->_lookupArtistPicture() if @artistsToLookUp && !$artistLookup;
}

sub _lookupArtistPicture {
	my ($self) = @_;

	if ( !scalar @artistsToLookUp ) {
		$artistLookup = 0;
	}
	else {
		$artistLookup = 1;
		$self->getArtist(sub { $self->_lookupArtistPicture() }, shift @artistsToLookUp);
	}
}

sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	# need to get a token first?
	my $token = '';

	if ($url ne 'user/login' && blessed $self) {
		$token = ($params->{_cid} || 0)
			? Plugins::Qobuz::API::Common->getWebToken($self->userId)
			: Plugins::Qobuz::API::Common->getToken($self->userId);
		if ( !$token ) {
			$log->error('No or invalid user session');
			return $cb->();
		}
	}

	$params->{user_auth_token} = $token if delete $params->{_use_token};

	$params ||= {};

	my @query;
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}

	my $appId = (delete $params->{_cid} && $cid) || $aid;
	push @query, "app_id=$appId";

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
		$data =~ s/(?:$aid|$token|$cid)//g;
		$log->info($data);
	}

	my $cacheKey = $url . ($params->{_user_cache} ? $self->userId : '');

	if ($params->{_wipecache}) {
		$cache->remove($cacheKey);
	}

	if (!$params->{_nocache} && (my $cached = $cache->get($cacheKey))) {
		main::DEBUGLOG && $log->is_debug && $log->debug("found cached response: " . Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	my %headers = (
		'X-User-Auth-Token' => $token,
		'X-App-Id' => $appId,
	);

	$headers{'User-Agent'} = ($prefs->get('useragent') || BROWSER_UA) if $appId == $cid;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $url !~ /getFileUrl/i && $log->debug(Data::Dump::dump($result));

			if ($result && !$params->{_nocache}) {
				if ( !($params->{album_id}) || ( $result->{release_date_stream} && $result->{release_date_stream} lt Slim::Utils::DateTime::shortDateF(time, "%Y-%m-%d") ) ) {
					$cache->set($cacheKey, $result, $params->{_ttl} || QOBUZ_DEFAULT_EXPIRY);
				}
			}

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->();
		},
		{
			timeout => 15,
		},
	)->get($url, %headers);
}

sub _pagingGet {
	my ( $self, $url, $cb, $params ) = @_;

	my $limit = $params->{limit};
	$params->{limit} = min($params->{limit}, QOBUZ_LIMIT);

	my $getMaxFn = ref $params->{_maxKey} ? delete $params->{_maxKey} : sub {
		my ($results) = @_;
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

	$self->_get($url, sub {
		my ($result) = @_;

		my $total = $getMaxFn->($result) || QOBUZ_LIMIT;

		main::DEBUGLOG && $log->is_debug && $log->debug("Need another page? " . Data::Dump::dump({
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
				$self->_get($url, sub {
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

sub aid { $aid }

1;
