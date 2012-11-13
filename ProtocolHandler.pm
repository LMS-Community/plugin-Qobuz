package Plugins::Qobuz::ProtocolHandler;

# Handler for qobuz:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTP);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API;

my $log   = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;
	
	my ($id) = $url =~ m{^qobuz://([^\.]+)$};

	my $info = Plugins::Qobuz::API->getFileInfo($id || $url, undef, 1);
	
	return $info->{mime_type} =~ /flac/ ? 'flc' : 'mp3' if $info && $info->{mime_type};
	
	# fallback to configured setting - we'll hopefully fix this once we got full metadata
	return $prefs->get('preferredFormat') == 6 ? 'flc' : 'mp3';
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	
	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl(), $class->getFormatForURL($song->streamUrl()) );
}

sub parseDirectHeaders {
	my $class   = shift;
	my $client  = shift || return;
	my $url     = shift;
	my @headers = @_;
	
	# May get a track object
	if ( blessed($url) ) {
		$url = $url->url;
	}
	
	my $bitrate     = 750_000;
	my $contentType = 'flc';
	
	my $length;

	foreach my $header (@headers) {
		if ( $header =~ /^Content-Length:\s*(.*)/i ) {
			$length = $1;
			
		}
		elsif ( $header =~ m/^Content-Type:(mp3)/i ) {
			$bitrate = 320_000;
			$contentType = 'mp3';
		}
	}
	
	# try to calculate exact bitrate so we can display correct progress
	if ($length) {
		my $meta = $class->getMetadataFor($client, $url);
		$bitrate = $length*8 / $meta->{duration} if $meta->{duration};
	}
	
	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $url =~ m{^qobuz://([^\.]+)$};

	my $meta = {};
	$meta = Plugins::Qobuz::API->getTrackInfo($id) if $id;
	$meta->{type} = $class->getFormatForURL($url);
	$meta->{bitrate} = $meta->{type} eq 'mp3' ? '320_000' : '750_000';
	
	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $client = $song->master();
	my $url    = $song->currentTrack()->url;
	
	# Get next track
	my ($id) = $url =~ m{^qobuz://([^\.]+)$};
	
	my $streamData = Plugins::Qobuz::API->getFileInfo($id);

	if ($streamData) {
		$song->pluginData(mime => $streamData->{mime_type});
		$song->streamUrl(Plugins::Qobuz::API->getFileUrl($id));
		$successCb->();
		return;
	}
	
	$errorCb->('Failed to get next track', 'Qobuz');
}

1;