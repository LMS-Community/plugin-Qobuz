package Plugins::Qobuz::API::Sync;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(max);
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API::Common;

my $cache = Plugins::Qobuz::API::Common->getCache();
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my ($token, $aid, $as);

sub init {
	($aid, $as) = Plugins::Qobuz::API::Common->init(@_);
}

sub myArtists {
	my ($class, $userId) = @_;

	my $args = {
		type  => 'artists',
		limit => QOBUZ_LIMIT,
		_ttl => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	};

	my $total = 0;
	my $offset = 0;
	my $artists = [];

	do {
		$args->{offset} = $offset;

		my $response = $class->_get('favorite/getUserFavorites', $userId, $args);

		$offset = 0;

		if ( $response && ref $response && $response->{artists} && ref $response->{artists} && $response->{artists}->{items} && ref $response->{artists}->{items} ) {
			$total ||= $response->{artists}->{total};

			push @$artists, map {
				{
					id => $_->{id},
					name => $_->{name},
					image => Plugins::Qobuz::API::Common->getImageFromImagesHash($_->{image}),
				}
			} @{ $response->{artists}->{items} };

			if (scalar @$artists < $total && $response->{artists}->{total} > QOBUZ_LIMIT && $response->{artists}->{offset} < $response->{artists}->{total}) {
				$offset = $response->{artists}->{offset} + QOBUZ_LIMIT;
			}
		}
	} while $offset && $offset < QOBUZ_USERDATA_LIMIT;

	return $artists;
}

sub myAlbums {
	my ($class, $userId, $noPurchases) = @_;

	my $offset = 0;
	my $albums = [];

	my $args = {
		type  => 'albums',
		limit => QOBUZ_LIMIT,
		_ttl => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	};

	my @categories = ('favorite/getUserFavorites');
	push @categories, 'purchase/getUserPurchases' if !($noPurchases);

	foreach my $query (@categories) {
		do {
			$args->{offset} = $offset;

			my $response = $class->_get($query, $userId, $args);

			$offset = 0;

			if ( $response && ref $response && $response->{albums} && ref $response->{albums} && $response->{albums}->{items} && ref $response->{albums}->{items} ) {
				push @$albums, @{ _precacheAlbum($response->{albums}->{items}) };

				if ($response->{albums}->{total} > QOBUZ_LIMIT && $response->{albums}->{offset} < $response->{albums}->{total}) {
					$offset = $response->{albums}->{offset} + QOBUZ_LIMIT;
				}
			}
		} while $offset && $offset < QOBUZ_USERDATA_LIMIT;
	}

	return $albums;
}

sub getAlbum {
	my ($class, $userId, $albumId) = @_;

	my $args = {
		album_id => $albumId,
		limit    => QOBUZ_LIMIT,
	};

	my $total = 0;
	my $offset = 0;
	my $album;

	do {
		$args->{offset} = $offset;

		my $response = $class->_get('album/get', $userId, $args);

		$offset = 0;

		if ( $response && ref $response && $response->{tracks} && ref $response->{tracks} && $response->{tracks}->{items} && ref $response->{tracks}->{items} ) {
			$total ||= $response->{tracks}->{total};

			if ($album) {
				push @{$album->{tracks}->{items}}, @{$response->{tracks}->{items}};
			}
			else {
				$album = $response;
			}

			if (scalar @{$album->{tracks}->{items}} < $total && $response->{tracks}->{total} > QOBUZ_LIMIT && $response->{tracks}->{offset} < $response->{tracks}->{total}) {
				$offset = $response->{tracks}->{offset} + QOBUZ_LIMIT;
			}
		}
	} while $offset && $offset < QOBUZ_USERDATA_LIMIT;

	($album) = @{_precacheAlbum([$album])} if $album;

	return $album;
}

sub myPlaylists {
	my ($class, $userId, $limit) = @_;

	my $playlists = $class->_get('playlist/getUserPlaylists', $userId, {
		username => Plugins::Qobuz::API::Common->username($userId),
		limit    => QOBUZ_DEFAULT_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	});

	return ($playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists})
		? $playlists->{playlists}->{items}
		: [];
}

sub getPlaylistTracks {
	my ($class, $userId, $playlistId) = @_;

	my $offset = 0;
	my @playlistTracks;

	do {
		my $response = $class->_get('playlist/get', $userId, {
			playlist_id => $playlistId,
			extra       => 'tracks',
			limit       => QOBUZ_DEFAULT_LIMIT,
			offset      => $offset,
			_ttl        => QOBUZ_USER_DATA_EXPIRY,
			_use_token  => 1,
		});

		$offset = 0;

		if ($response && ref $response && $response->{tracks} && ref $response->{tracks} && $response->{tracks}->{items} && ref $response->{tracks}->{items}) {
			my $tracks = $response->{tracks}->{items};
			push @playlistTracks, @{_precacheTracks($tracks)};

			if (scalar $tracks && $response->{tracks}->{total} > $response->{tracks}->{offset} + QOBUZ_DEFAULT_LIMIT) {
				$offset = $response->{tracks}->{offset} + QOBUZ_DEFAULT_LIMIT;
			}
		}
	} while $offset && $offset < QOBUZ_USERDATA_LIMIT;

	return \@playlistTracks;
}

sub getArtist {
	my ($class, $userId, $artistId, $extra) = @_;

	$artistId =~ s/^qobuz:artist://;

	my $artist = $class->_get('artist/get', $userId, {
		artist_id => $artistId,
		(extra    => $extra || undef),
		limit     => QOBUZ_DEFAULT_LIMIT,
	});

	if ( $artist && (my $images = $artist->{image}) ) {
		my $pic = Plugins::Qobuz::API::Common->getImageFromImagesHash($images);
		$artist->{picture} ||= $pic if $pic;
	}

	$artist->{albums}->{items} = _precacheAlbum($artist->{albums}->{items}) if $artist->{albums};

	return $artist;
}

sub _get {
	my ( $class, $url, $userId, $params ) = @_;

	# need to get a token first?
	my $token = '';

	if ($url ne 'user/login') {
		$token = Plugins::Qobuz::API::Common->getToken($userId) || return {
			error => 'no access token',
		};
	}

	$params ||= {};
	$params->{user_auth_token} = $token if delete $params->{_use_token};

	my @query;
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}

	push @query, "app_id=$aid";

	$url = QOBUZ_BASE_URL . $url . '?' . join('&', sort @query);

	if (main::INFOLOG && $log->is_info) {
		my $data = $url;
		$data =~ s/(?:$aid|$token)//g;
		$log->info($data);
	}

	my $cacheKey = $url . ($params->{_user_cache} ? $userId : '');

	if (!$params->{_nocache} && (my $cached = $cache->get($cacheKey))) {
		main::INFOLOG && $log->is_info && $log->info("found cached response");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		return $cached;
	}

	my $response = Slim::Networking::SimpleSyncHTTP->new({ timeout => 15 })->get($url, 'X-User-Auth-Token' => $token, 'X-App-Id' => $aid);

	if ($response->code == 200) {
		my $result = eval { from_json($response->content) };

		$@ && $log->error($@);
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

		if ($result && !$params->{_nocache}) {
			if ( !($params->{album_id}) || ( $result->{release_date_stream} && $result->{release_date_stream} lt Slim::Utils::DateTime::shortDateF(time, "%Y-%m-%d") ) ) {
				$cache->set($cacheKey, $result, $params->{_ttl} || QOBUZ_DEFAULT_EXPIRY);
			}
		}

		return $result;
	}
	else {
		$url =~ s/app_id=\d*//;
		$log->error("Request failed for $url");
		main::INFOLOG && $log->info(Data::Dump::dump($response));
	}

	return;
}

1;