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

sub new {
	my $class  = shift;
	my $args   = shift;

	my $client    = $args->{client};
	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
	
	main::DEBUGLOG && $log->is_debug && $log->debug( 'Remote streaming Qobuz track: ' . $streamUrl );

	my $mime = $song->pluginData('mime');

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
#		bitrate => $mime =~ /flac/i ? 750_000 : 320_000,
	} ) || return;
	
	${*$sock}{contentType} = $mime;

	return $sock;
}

sub canSeek { 0 }
sub getSeekDataByPosition { undef }
sub getSeekData { undef }

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;
	
	my ($id) = $url =~ m{^qobuz://([^\.]+)$};

	my $info = Plugins::Qobuz::API->getCachedFileInfo($id || $url);
	
	return $info->{mime_type} =~ /flac/ ? 'flc' : 'mp3' if $info && $info->{mime_type};
	
	# fallback to configured setting - we'll hopefully fix this once we got full metadata
	return $prefs->get('preferredFormat') == 6 ? 'flc' : 'mp3';
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;
	
	# We need to check with the base class (HTTP) to see if we
	# are synced or if the user has set mp3StreamingMethod
	return $class->SUPER::canDirectStream( $client, $song->streamUrl() );
}

# parseHeaders is used for proxied streaming
sub parseHeaders {
	my ( $self, @headers ) = @_;
	
	__PACKAGE__->parseDirectHeaders( $self->client, $self->url, @headers );
	
	return $self->SUPER::parseHeaders( @headers );
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

	my $song = $client->streamingSong();
	
	# try to calculate exact bitrate so we can display correct progress
	my $meta = $class->getMetadataFor($client, $url);
	my $duration = $meta->{duration};
	$song->duration($duration);
	
	if ($length) {
		$bitrate = $length*8 / $duration if $meta->{duration};
		$song->bitrate($bitrate) if $bitrate;
	}
	
	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $url =~ m{^qobuz://([^\.]+)$};
	$id ||= $url; 

	my $meta;
	
	# grab metadata from backend if needed, otherwise use cached values
	if ($id && $client->master->pluginData('fetchingMeta')) {
		$meta = Plugins::Qobuz::API->getCachedFileInfo($id);
	}
	elsif ($id) {
		$client->master->pluginData( fetchingMeta => 1 );

		$meta = Plugins::Qobuz::API->getTrackInfo(sub {
			$client->master->pluginData( fetchingMeta => 0 );
		}, $id);
	}
	
	$meta ||= {};
	$meta->{type} = $class->getFormatForURL($url);
	$meta->{bitrate} = $meta->{type} eq 'mp3' ? 320_000 : 750_000;
	
	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $url    = $song->currentTrack()->url;
	
	# Get next track
	my ($id) = $url =~ m{^qobuz://([^\.]+)$};
	
	Plugins::Qobuz::API->getFileInfo(sub {
		my $streamData = shift;

		if ($streamData) {
			$song->pluginData(mime => $streamData->{mime_type});
			Plugins::Qobuz::API->getFileUrl(sub {
				$song->streamUrl(shift);
				$successCb->();
			}, $id);
			return;
		}
		
		$errorCb->('Failed to get next track', 'Qobuz');
	}, $id);
}

sub audioScrobblerSource {
	# Scrobble as 'chosen by user' content
	return 'P';
}

1;