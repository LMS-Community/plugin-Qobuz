package Plugins::Qobuz::API::Common;

use strict;
use Exporter::Lite;

our @EXPORT = qw(
	QOBUZ_BASE_URL QOBUZ_DEFAULT_EXPIRY QOBUZ_USER_DATA_EXPIRY QOBUZ_EDITORIAL_EXPIRY QOBUZ_DEFAULT_LIMIT QOBUZ_LIMIT QOBUZ_USERDATA_LIMIT
	QOBUZ_STREAMING_MP3 QOBUZ_STREAMING_FLAC QOBUZ_STREAMING_FLAC_HIRES QOBUZ_STREAMING_FLAC_HIRES2
	_precacheAlbum _precacheTracks precacheTrack
);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant QOBUZ_BASE_URL => 'https://www.qobuz.com/api.json/0.2/';

use constant QOBUZ_DEFAULT_EXPIRY   => 86400 * 30;
use constant QOBUZ_USER_DATA_EXPIRY => 60;            # user want to see changes in purchases, playlists etc. ASAP
use constant QOBUZ_EDITORIAL_EXPIRY => 60 * 60;       # editorial content like recommendations, new releases etc.

use constant QOBUZ_DEFAULT_LIMIT  => 200;
use constant QOBUZ_LIMIT          => 500;
use constant QOBUZ_USERDATA_LIMIT => 5000;            # users know how many results to expect - let's be a bit more generous :-)

use constant QOBUZ_STREAMING_MP3  => 5;
use constant QOBUZ_STREAMING_FLAC => 6;
use constant QOBUZ_STREAMING_FLAC_HIRES => 7;
use constant QOBUZ_STREAMING_FLAC_HIRES2 => 27;

my $cache;
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');
my $isClassique;
my %genreList;

initGenreMap();

$prefs->setChange(\&initGenreMap, 'classicalGenres');

sub init {
	return pack('H*', $_[2]) =~ /^(\d{9})([a-f0-9]{32})(\d{9})/i
}

sub initGenreMap {
   %genreList = map { $_ => 1 } split /\s*,\s*/, $prefs->get('classicalGenres');
}

sub getCache {
	return $cache ||= Slim::Utils::Cache->new('qobuz', 4);
}

sub getAccountList {
	return [ grep {
		$_->[0] && $_->[1]
	} map {[
		$_->{userdata}->{display_name} || $_->{userdata}->{login},
		$_->{userdata}->{id},
		$_->{dontimport}
	]} sort {
		lc($a->{userdata}->{display_name} || $a->{userdata}->{login}) cmp lc($b->{userdata}->{display_name} || $b->{userdata}->{login});
	} values %{ $prefs->get('accounts') } ];
}

sub hasAccount {
	return scalar @{ getAccountList() } ? 1 : 0;
}

sub getAccountData {
	my ($class, $clientOrUserId) = @_;

	my $accounts = $prefs->get('accounts') || return;

	my $userId = ref $clientOrUserId
		? $prefs->client($clientOrUserId)->get('userId')
		: $clientOrUserId;

	return $accounts->{$userId};
}

sub getSomeUserId {
	my ($class) = @_;

	my ($userId) = map { $_->[1] } @{ $class->getAccountList };
	return $userId;
}

sub getToken {
	my ($class, $clientOrUserId) = @_;

	my $account = $class->getAccountData($clientOrUserId) || return;
	return $account->{token};
}

sub getWebToken {
	my ($class, $clientOrUserId) = @_;

	my $account = $class->getAccountData($clientOrUserId) || return;
	return $account->{webToken};
}

sub getUserdata {
	my ($class, $clientOrUserId, $item) = @_;

	my $account = $class->getAccountData($clientOrUserId) || return;
	my $userdata = $account->{'userdata'} || return;

	return $item ? $userdata->{$item} : $userdata;
}

sub getCredentials {
	my ($class, $client) = @_;

	my $credentials = $class->getUserdata($client, 'credential');

	if ($credentials && ref $credentials) {
		return $credentials;
	}
}

sub getDevicedata {
	my ($class, $client) = @_;
	$class->getUserdata($client, 'device') || {};
}

sub username {
	my ($class, $clientOrUserId) = @_;
	$class->getUserdata($clientOrUserId, 'login');
}

sub getArtistName {
	my ($class, $track, $album) = @_;
	$track->{performer} ||= $album->{performer} || {};
	return $track->{performer}->{name} || $album->{artist}->{name} || '',
}

sub filterPlayables {
	my ($class, $items) = @_;

	return $items if $prefs->get('playSamples');

	return [ grep {
		!$_->{released_at} || $_->{streamable};  # allow all tracks and streamable albums
	} @$items ];
}

sub _precacheAlbum {
	my ($albums) = @_;

	return unless $albums && ref $albums eq 'ARRAY';

	$albums = __PACKAGE__->filterPlayables($albums);

	foreach my $album (@$albums) {
		foreach (qw(composer duration articles article_ids catchline
			# maximum_bit_depth maximum_channel_count maximum_sampling_rate maximum_technical_specifications
			popularity previewable qobuz_id sampleable slug streamable_at subtitle created_at
			product_type product_url purchasable purchasable_at relative_url release_date_download release_date_original
			product_sales_factors_monthly product_sales_factors_weekly product_sales_factors_yearly))
		{
			delete $album->{$_};
		}

		$album->{genre} = $album->{genre}->{name};
		$album->{image} = __PACKAGE__->getImageFromImagesHash($album->{image}) || '';

		# If the user pref is for classical music enhancements to the display, is this a classical release or has the user added the genre to their custom classical list?
		$isClassique = 0;
		if ( $prefs->get('useClassicalEnhancements') ) {
			if ( ( $album->{genres_list} && grep(/Classique/,@{$album->{genres_list}}) ) || $genreList{$album->{genre}} ) {
				$isClassique = 1;
			}
		}

		my $albumInfo = {
			title  => $album->{title},
			id     => $album->{id},
			artist => $album->{artist},
			image  => $album->{image},
			year   => substr($album->{release_date_stream},0,4),
			goodies=> $album->{goodies},
			genre  => $album->{genre},
			genres_list => $album->{genres_list},
			isClassique => $isClassique,
			parental_warning => $album->{parental_warning},
			media_count => $album->{media_count},
			duration => 0,
			release_type => $album->{release_type},
			label => $album->{label}->{name},
			labelId => $album->{label}->{id},
		};

		_precacheTracks([ map {
			$_->{album} = $albumInfo;
			$_;
		} @{$album->{tracks}->{items}} ]);

		if (defined $albumInfo->{replay_gain}) {
			$album->{replay_gain} = $albumInfo->{replay_gain};
			$album->{replay_peak} = $albumInfo->{replay_peak};
			$cache->set('albumInfo_' . $albumInfo->{id}, $albumInfo, QOBUZ_DEFAULT_EXPIRY);
		}
		elsif ($albumInfo = $cache->get('albumInfo_' . $album->{id})) {
			if (defined $albumInfo->{replay_gain}) {
				$album->{replay_gain} = $albumInfo->{replay_gain};
			}
		}
	}

	return $albums;
}

sub _precacheTracks {
	my ($tracks) = @_;

	return unless $tracks && ref $tracks eq 'ARRAY';

	$tracks = __PACKAGE__->filterPlayables($tracks);

	foreach my $track (@$tracks) {
		foreach (qw(article_ids copyright downloadable isrc previewable purchasable purchasable_at)) {
			delete $track->{$_};
		}

		precacheTrack($track)
	}

	return $tracks;
}

sub precacheTrack {
	my ($class, $track) = @_;

	if ( !$track && ref $class eq 'HASH' ) {
		$track = $class;
		$class = __PACKAGE__;
	}

	my $album = $track->{album} || {};
	$track->{composer} ||= $album->{composer} || {};

	my $meta = {
		title    => $track->{title} || $track->{id},
		album    => $album->{title} || '',
		albumId  => $album->{id},
		artist   => $class->getArtistName($track, $album),
		artistId => $album->{artist}->{id} || '',
		composer => $track->{composer}->{name} || '',
		composerId => $track->{composer}->{id} || '',
		performers => $track->{performers} || '',
		cover    => $album->{image},
		duration => $track->{duration} || 0,
		year     => $album->{year} || substr($album->{release_date_stream},0,4) || 0,
		goodies  => $album->{goodies},
		version  => $track->{version},
		work     => $track->{work},
		genre    => $album->{genre},
		genres_list => $album->{genres_list},
		isClassique => $isClassique,
		parental_warning => $track->{parental_warning},
		track_number => $track->{track_number},
		media_number => $track->{media_number},
		media_count => $album->{media_count},
		label => ref $album->{label} ? $album->{label}->{name} : $album->{label},
		labelId => ref $album->{label} ? $album->{label}->{id} : $album->{labelId},
	};

	if ($track->{audio_info}) {
		my $updateAlbumGain = 0;
		if (defined $track->{audio_info}->{replaygain_track_gain}) {
			$meta->{replay_gain} = $track->{audio_info}->{replaygain_track_gain};
			if (!defined $album->{replay_gain} || ($album->{replay_gain} > $meta->{replay_gain})) {
				$updateAlbumGain = 1;
				$album->{replay_gain} = $meta->{replay_gain};
			}
		}

		if (defined $track->{audio_info}->{replaygain_track_peak}) {
			$meta->{replay_peak} = $track->{audio_info}->{replaygain_track_peak};
			if ($updateAlbumGain) {
				$album->{replay_peak} = $meta->{replay_peak};
			}
		}
	}

	$album->{duration} += $meta->{duration};
	main::DEBUGLOG && $log->is_debug && $log->debug("Track $meta->{title} precached");
	$cache->set('trackInfo_' . $track->{id}, $meta, ($meta->{duration} ? QOBUZ_DEFAULT_EXPIRY : QOBUZ_EDITORIAL_EXPIRY));

	return $meta;
}

sub addVersionToTitle {
	my ($class, $track) = @_;

	if ($track->{version} && $prefs->get('appendVersionToTitle')) {
		$track->{title} .= " ($track->{version})";
	}

	return $track->{title};
}

sub getStreamingFormat {
	my ($class, $track) = @_;

	# user prefers mp3 over flac anyway
	if ($prefs->get('preferredFormat') < QOBUZ_STREAMING_FLAC) {
		return 'mp3';
	}

	if ($track && !ref $track && $track =~ /fmt=(\d+)/) {
		return $1 >= QOBUZ_STREAMING_FLAC ? 'flac' : 'mp3';
	}

	return 'flac';
}

sub getUrl {
	my ($class, $client, $track) = @_;

	return '' unless $track;

	my $ext = $class->getStreamingFormat($track);

	$track = $track->{id} if $track && ref $track eq 'HASH';

	return 'qobuz://' . $track . '.' . $ext;
}

sub getImageFromImagesHash {
	my ($class, $images) = @_;

	return $images unless ref $images;
	return $images->{mega} || $images->{extralarge} || $images->{large} || $images->{medium} || $images->{small} || $images->{thumbnail};
}

sub getPlaylistImage {
	my ($class, $playlist) = @_;

	my $image;
	# pick the last image, as this is what is shown top most in the Qobuz Desktop client
	foreach ('image_rectangle', 'images300', 'images_300', 'images150', 'images_150', 'images') {
		if ($playlist->{$_} && ref $playlist->{$_} eq 'ARRAY') {
			$image = $playlist->{$_}->[-1];
			last;
		}
	}
	$image =~ s/([a-z\d]{13}_)[\d]+(\.jpg)/${1}600$2/;

	return $image;
}

1;
