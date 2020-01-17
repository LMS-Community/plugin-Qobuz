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

use constant QOBUZ_BASE_URL => 'http://www.qobuz.com/api.json/0.2/';

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

sub init {
	my $class = shift;
	return pack('H*', $_[0]) =~ /^(\d{9})(.*)/
}

sub getCache {
	return $cache ||= Slim::Utils::Cache->new('qobuz', 8);
}

sub getUserdata {
	my ($class, $item) = @_;

	my $userdata = $cache->get('userdata') || {};

	return $item ? $userdata->{$item} : $userdata;
}

sub getCredentials {
	my $credentials = $_[0]->getUserdata('credential');

	if ($credentials && ref $credentials) {
		return $credentials;
	}
}

sub getDevicedata {
	$_[0]->getUserdata('device') || {};
}

sub username {
	return $_[0]->getUserdata('login') || $prefs->get('username');
}

sub getArtistName {
	my ($class, $track, $album) = @_;
	$track->{performer} ||= $album->{performer} || {};
	return $track->{performer}->{name} || $album->{artist}->{name} || '',
}

sub filterPlayables {
	my ($class, $items) = @_;

	return $items if $prefs->get('playSamples');

	my $t = time;
	return [ grep {
		($_->{released_at} ? $_->{released_at} <= $t : 1) && $_->{streamable};
	} @$items ];
}

sub _precacheAlbum {
	my ($albums) = @_;

	return unless $albums && ref $albums eq 'ARRAY';

	$albums = __PACKAGE__->filterPlayables($albums);

	foreach my $album (@$albums) {
		delete $album->{articles};
		delete $album->{article_ids};

		my $albumInfo = {
			title  => $album->{title},
			id     => $album->{id},
			artist => $album->{artist},
			image  => $album->{image},
			year   => (localtime($album->{released_at}))[5] + 1900,
			goodies=> $album->{goodies},
		};

		foreach my $track (@{$album->{tracks}->{items}}) {
			$track->{album} = $albumInfo;
			precacheTrack($track);
		}
	}

	return $albums;
}

sub _precacheTracks {
	my ($tracks) = @_;

	return unless $tracks && ref $tracks eq 'ARRAY';

	$tracks = __PACKAGE__->filterPlayables($tracks);

	foreach my $track (@$tracks) {
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
		cover    => $album->{image}->{large} || '',
		duration => $track->{duration} || 0,
		year     => $album->{year} || (localtime($album->{released_at}))[5] + 1900 || 0,
		goodies  => $album->{goodies},
	};

	$cache->set('trackInfo_' . $track->{id}, $meta, ($meta->{duration} ? QOBUZ_DEFAULT_EXPIRY : QOBUZ_EDITORIAL_EXPIRY));

	return $meta;
}

# figure out what streaming format we can use
# - check preference
# - fall back to mp3 samples if not streamable
# - check user's subscription level
sub getStreamingFormat {
	my ($class, $track) = @_;

	if (
		# user prefers mp3 over flac anyway
		$prefs->get('preferredFormat') < QOBUZ_STREAMING_FLAC
		# user is not allowed to stream losslessly
		|| !$class->canLossless()
		# track is not available in flac
		|| !($track && ref $track eq 'HASH' && $track->{streamable})
	) {
		return 'mp3';
	}

	return 'flac';
}

sub canLossless {
	my ($class) = @_;

	my $credentials = $class->getCredentials;
	return ($credentials && ref $credentials && $credentials->{parameters} && ref $credentials->{parameters} && $credentials->{parameters}->{lossless_streaming});
}

sub getUrl {
	my ($class, $id) = @_;

	return '' unless $id;

	my $ext = $class->getStreamingFormat($id);

	$id = $id->{id} if $id && ref $id eq 'HASH';

	return 'qobuz://' . $id . '.' . $ext;
}

1;