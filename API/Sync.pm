package Plugins::Qobuz::API::Sync;

use strict;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);

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

	main::INFOLOG && $log->is_info && !$log->is_debug && $log->info(Data::Dump::dump($result));

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
	my $albums = [];
	my $libraryMeta;

	my $args = {
		type  => 'albums',
		limit => QOBUZ_LIMIT,
		_ttl => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
	};

	do {
		$args->{offset} = $offset;

		my $response = $class->_get('favorite/getUserFavorites', $args);

		$offset = 0;

		if ( $response && $response->{albums} && ref $response->{albums} && $response->{albums}->{items} && ref $response->{albums}->{items} ) {
			# keep track of some meta-information about the album collection
			$libraryMeta ||= {
				total => $response->{albums}->{total} || 0,
				lastAdded => $response->{albums}->{items}->[0]->{favorited_at} || ''
			};

			$albums = _precacheAlbum($response->{albums}->{items});

			if (scalar @$albums < $libraryMeta->{total}) {
				$offset = $response->{albums}->{offset} + 1;
			}
		}
	} while $offset;

	return wantarray ? ($albums, $libraryMeta) : $albums;
}

sub getAlbum {
	my ($class, $albumId) = @_;

	my $album = $class->_get('album/get', {
		album_id => $albumId,
	});

	($album) = @{_precacheAlbum([$album])} if $album;

	return $album;
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
		warn Data::Dump::dump($response);
		# # login failed due to invalid username/password: delete password
		# if ($error =~ /^401/ && $http->url =~ m|user/login|i) {
		# 	$prefs->remove('password_md5_hash');
		# }

		# $log->warn("Error: $error");
	}

	return;
}

1;