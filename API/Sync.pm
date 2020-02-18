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
	my $class = shift;
	($aid, $as) = Plugins::Qobuz::API::Common->init(@_);

	# try to get a token if needed - pass empty callback to make it look it up anyway
	$class->getToken(sub {}, !Plugins::Qobuz::API::Common->getCredentials);
}

sub getToken {
	my ($class) = @_;

	my $username = $prefs->get('username');
	my $password = $prefs->get('password_md5_hash');

	return unless $username && $password;

	return $token if $token;

	my $result = $class->_get('user/login', {
		username => $username,
		password => $password,
		device_manufacturer_id => preferences('server')->get('server_uuid'),
		_nocache => 1,
	});

	main::INFOLOG && $log->is_info && !$log->is_info && $log->info(Data::Dump::dump($result));

	if ( ! ($result && ($token = $result->{user_auth_token})) ) {
		$log->warn('Failed to get token');
		return;
	}

	# keep the user data around longer than the token
	$cache->set('userdata', $result->{user}, time() + QOBUZ_DEFAULT_EXPIRY*2);

	return $token;
}

sub myAlbums {
	my ($class) = @_;

	my $offset = 0;
	my $allAlbums = [];
	my $libraryMeta;

	my $args = {
		type  => 'albums',
		limit => QOBUZ_LIMIT,
		_ttl => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
	};

	my ($total, $lastAdded) = (0, 0);

	foreach my $query ('favorite/getUserFavorites', 'purchase/getUserPurchases') {
		my $gotMeta;
		my $albums = [];

		do {
			$args->{offset} = $offset;

			my $response = $class->_get($query, $args);

			$offset = 0;

			if ( $response && ref $response && $response->{albums} && ref $response->{albums} && $response->{albums}->{items} && ref $response->{albums}->{items} ) {
				if (!$gotMeta) {
					if ($query =~ /purchase/) {
						my @timestamps = map { $_->{purchased_at} } @{ $response->{albums}->{items} };
						$lastAdded = max($lastAdded, @timestamps);
					}
					else {
						$lastAdded = max($lastAdded, $response->{albums}->{items}->[0]->{favorited_at} || 0);
					}

					$total += $response->{albums}->{total};
					$gotMeta = 1;
				}

				push @$albums, @{ _precacheAlbum($response->{albums}->{items}) };

				if (scalar @$albums < $libraryMeta->{total}) {
					$offset = $response->{albums}->{offset} + 1;
				}
			}
		} while $offset;

		push @$allAlbums, @$albums;
	}

	if ($total && $lastAdded) {
		# keep track of some meta-information about the album collection
		$libraryMeta = {
			total => $total,
			lastAdded => $lastAdded
		};
	}

	return wantarray ? ($allAlbums, $libraryMeta) : $allAlbums;
}

sub getAlbum {
	my ($class, $albumId) = @_;

	my $album = $class->_get('album/get', {
		album_id => $albumId,
	});

	($album) = @{_precacheAlbum([$album])} if $album;

	return $album;
}

sub myPlaylists {
	my ($class, $limit) = @_;

	my $playlists = $class->_get('playlist/getUserPlaylists', {
		username => Plugins::Qobuz::API::Common->username,
		limit    => QOBUZ_DEFAULT_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
	});

	return ($playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists})
		? $playlists->{playlists}->{items}
		: [];
}

sub getPlaylistTracks {
	my ($class, $playlistId) = @_;

	my $offset = 0;
	my @playlistTracks;

	do {
		my $response = $class->_get('playlist/get', {
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
	my ($class, $artistId, $extra) = @_;

	$artistId =~ s/^qobuz:artist://;

	my $artist = $class->_get('artist/get', {
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
	my ( $class, $url, $params ) = @_;

	# need to get a token first?
	my $token = '';

	if ($url ne 'user/login') {
		$token = $class->getToken() || return {
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

	if (!$params->{_nocache} && (my $cached = $cache->get($url))) {
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
			$cache->set($url, $result, $params->{_ttl} || QOBUZ_DEFAULT_EXPIRY);
		}

		return $result;
	}
	else {
		$url =~ s/app_id=\d*//;
		$log->error("Request failed for $url");
		main::INFOLOG && $log->info(Data::Dump::dump($response));
		# # login failed due to invalid username/password: delete password
		# if ($error =~ /^401/ && $http->url =~ m|user/login|i) {
		# 	$prefs->remove('password_md5_hash');
		# }

		# $log->warn("Error: $error");
	}

	return;
}

1;