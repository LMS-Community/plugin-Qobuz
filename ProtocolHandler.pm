package Plugins::Qobuz::ProtocolHandler;

# Handler for qobuz:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTP);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
#use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use List::Util qw(min max first);
use Slim::Utils::Errno;

# Size of the _sysread chunksize AND buffers, NOT to be confuesed with same applied to pipeline and/or player.

use constant MAX_OUT => 512*1024*1024; # safety limit, the out should always be empty, if reached _sysread stops reading from source.

use constant MIN_OUT => 256*1024; # data are not transferred to output until this limit is reached in input.
use constant RANGE_SIZE => 1024*1024; # size of range in the http get request, not really the chunksize, but similar.

# Note that playback will not start untill the firs http get returns, so the greather value between RANGE_SIZE and MIN_OUT, is the real 
# threshold.

# Seconds of delay before playback starts (initial buffering seconds)
use constant BUFFERING_SECONDS => 5;

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::Reporting;

use constant MP3_BITRATE => 320_000;

use constant PAGE_URL_REGEXP => qr{open.qobuz.com/(.+)/([a-z0-9]+)};
Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__) if Slim::Player::ProtocolHandlers->can('registerURLHandler');

my $log = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub new {
	my $class = shift;
	my $args = shift;

	my $client = $args->{client};
	my $song = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	main::DEBUGLOG && $log->is_debug && $log->debug( 'Remote streaming Qobuz track: ' . $streamUrl );

	my $mime = $song->pluginData('mime');

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
#		bitrate => $mime =~ /flac/i ? 750_000 : MP3_BITRATE,
	} ) || return;

	${*$sock}{contentType} = $mime;

	if (defined($sock)) {
		${*$sock}{'vars'} = { # variables which hold state for this instance:
			'inBuf' => '', # buffer of received data
			'outBuf' => '',# buffer of data data ready to be processed
			'offset' => 0, # offset for next HTTP request
			'streaming' => 1, # flag for streaming, changes to 0 when all data received
			'fetching' => 0, # waiting for HTTP data
		};
	}
	return $sock;
}

sub vars {
	return ${*{$_[0]}}{'vars'};
}

# The real delay is caused by max between bufferThreshold*1000 and RANGE_SIZE,
# no data could be returned before the first chunk is here.
# If this method is omitted, then player.pm will try to calculate the value using 
# bitrate and buffersec preference (that is also used to size the buffer), limited
# at 255 Kb, good for mp3, maybe little for flac 44100/16, inadeguate for HiRez.
#
# THE FOLLOWING SEEMS NOT TO WORK...
#

sub bufferThreshold{
	my ($class, $client, $url) = @_;

	#We have bufferThreshold in prefs, let's use it.
	my $clientPrefs= $prefs->client($client);

	my $bufferThreshold= $clientPrefs->get('bufferThreshold');

	if ($bufferThreshold){return $bufferThreshold};

	my $bufferSecs = $prefs->get('bufferSecs') || BUFFERING_SECONDS;
	#limit to BUFFERING_SECONDS seconds.
	if ($bufferSecs > BUFFERING_SECONDS){$bufferSecs = BUFFERING_SECONDS;}

	my $format = $class->getFormatForURL($url);

	return ($format eq 'flc' ? 80 : 32) * $bufferSecs;

}

sub sysread {
	my $self = $_[0];
	#my $chunk = $_[1];
	my $chunkSize = $_[2];

	my $metaInterval = ${*$self}{'metaInterval'};
	my $metaPointer = ${*$self}{'metaPointer'};
 
	#Data::Dump::dump("Plugins::Qobuz::ProtocolHandler - sysread: ", $metaInterval, $metaPointer, $chunkSize);
	my $readLength;

	#Data::Dump::dump("useChunkedHttpGet: ",$prefs->get('useChunkedHttpGet'));
	#Data::Dump::dump("httpRangeSize: ", $prefs->get('httpRangeSize'));
 
	if ($metaInterval && ($metaPointer + $chunkSize) > $metaInterval) {

		$chunkSize = $metaInterval - $metaPointer;

		# This is very verbose...
		#$log->debug("Reduced chunksize to $chunkSize for metadata");

		$readLength = CORE::sysread($self, $_[1], $chunkSize, length($_[1] || '' ))
		
	} elsif (!$prefs->get('useChunkedHttpGet')) { 
		#Data::Dump::dump("CORE::sysread: ", $chunkSize);
		$readLength = CORE::sysread($self, $_[1], $chunkSize, length($_[1] || ''));

	} else {
		#Data::Dump::dump("_sysread: ", $prefs->get('httpRangeSize')*1024 || RANGE_SIZE);
		$readLength = _sysread($self, $_[1]);
	}
 
	if ($metaInterval && $readLength) {

		$metaPointer += $readLength;
		${*$self}{'metaPointer'} = $metaPointer;

		# handle instream metadata for shoutcast/icecast
		if ($metaPointer == $metaInterval) {

			$self->readMetaData();

			${*$self}{'metaPointer'} = 0;

		} elsif ($metaPointer > $metaInterval) {

			main::DEBUGLOG && $log->debug("The shoutcast metadata overshot the interval.");
		}	
	}

	return $readLength;
}

sub _sysread(){
	use bytes;

	my $self = $_[0];

	my $client = $self->client;
	my $maxOut = $client->bufferSize() || MAX_OUT;
	my $rangeSize = $prefs->get('httpRangeSize')*1024 || RANGE_SIZE;

	my $v = $self->vars;
	my $url = ${*$self}{'url'};

	# need more data
	if ( length $v->{'outBuf'} < $maxOut && !$v->{'fetching'}) {

		my $range;
		#Data::Dump::dump("_sysread: fetching", $rangeSize);
		
		if ($v->{'streaming'}){

			$range = "bytes=$v->{offset}-" . ($v->{offset} + $rangeSize - 1);

		} else {

			$range = "bytes=$v->{offset}-" . ($v->{offset} + 1);
		}

		$v->{'fetching'} = 1;

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				$v->{'inBuf'} .= $_[0]->content;
				$v->{'fetching'} = 0;
				$v->{'streaming'} = 0 if length($_[0]->content) < $rangeSize;
				$v->{offset} += length($_[0]->content);

				main::DEBUGLOG && $log->is_debug && $log->debug("got chunk length: ", length $_[0]->content, " from ", $v->{offset} - $rangeSize, " for $url");
			},
			sub { 
				$log->warn("error fetching $url");
				$v->{'inBuf'} = '';
				$v->{'fetching'} = 0;
			}, 

		)->get($url, 'Range' => $range );
	}
	
	# This is the size of chunck of data moved from in to out buffers.
	# Standard id 32Kb, resulting in a higly inefficent move.
	# Move the entire range size or MIN_OUT instead.
	
	my $chunckSize = max($rangeSize, MIN_OUT);

	if (length $v->{'inBuf'} >= $chunckSize || !$v->{'streaming'}){
		
		#Data::Dump::dump("_sysread: move to Outbuf", length $v->{'inBuf'});
		
		$v->{'outBuf'} = $v->{'outBuf'}.$v->{'inBuf'};
		$v->{'inBuf'}='';
	}

	my $bytes =length $v->{'outBuf'};

	if ($bytes) {
		
		#Data::Dump::dump("_sysread: move to pipeline", $bytes);
		
		$_[1] = $_[1].substr($v->{'outBuf'}, 0, $bytes);
		$v->{'outBuf'} = substr($v->{'outBuf'}, $bytes);
		return $bytes;

	} elsif ( $v->{streaming} ) {
		#$! = EINTR; Pipeline does not recocgnize EINTR;
		$! = EWOULDBLOCK;
		return undef;
	} else {
		#Data::Dump::dump("EOF");
		return 0; #EOF.
	}
}

sub canSeek { 1 }

sub getSeekDataByPosition { undef }

sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;

	my $url = $song->currentTrack()->url() || return;

	my ($id, $type) = $class->crackUrl($url);

	my $bitrate = $type eq 'mp3' ? MP3_BITRATE : $song->bitrate();

	return unless $bitrate;

	return {
		sourceStreamOffset => ( $bitrate  * $newtime ) / 8,
		timeOffset         => $newtime,
	};
}

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;

	my ($id, $type) = $class->crackUrl($url);

	if ($type =~ /^(flac|mp3)$/) {
		$type =~ s/flac/flc/;
		return $type;
	}

	my $info = Plugins::Qobuz::API->getCachedFileInfo($id || $url);

	return $info->{mime_type} =~ /flac/ ? 'flc' : 'mp3' if $info && $info->{mime_type};

	# fall back to whatever the user can play
	return Plugins::Qobuz::API::Common->getStreamingFormat();
}

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	if (my ($type, $id) = $url =~ PAGE_URL_REGEXP) {
		if ($type eq 'track') {
			$url = "qobuz://$id." . Plugins::Qobuz::API::Common->getStreamingFormat($url);
		}
		else {
			$url = "qobuz://$type:$id.qbz";
		}
	}

	if ( $url =~ m{^qobuz://(playlist|album)?:?([0-9a-z]+)\.qbz}i ) {
		my $type = $1;
		my $id = $2;

		my $getter = $type eq 'album' ? 'getAlbum' : 'getPlaylistTracks';

		Plugins::Qobuz::API->$getter(sub {
			my $response = shift || [];

			my $uris = [];

			if ($response && ref $response && $response->{tracks}) {
				$uris = [ map {
					Plugins::Qobuz::API::Common->getUrl($_);
				} @{$response->{tracks}->{items}} ]
			}

			$cb->($uris);
		}, $id);
	}
	else {
		$cb->([$url])
	}
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
	my $class = shift;
	my $client = shift || return;
	my $url = shift;
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
		# allows seeking in flac files, see getSeekData()
		elsif ( $header =~ /^Content-Range:.*\/+(.*)/i ) {
			$length = $1;
		}
		elsif ( $header =~ /^Content-Type:.*(?:mp3|mpeg)/i ) {
			$bitrate = MP3_BITRATE;
			$contentType = 'mp3';
		}
	}

	my $song = $client->streamingSong();

	# try to calculate exact bitrate so we can display correct progress
	my $meta = $class->getMetadataFor($client, $url);
	my $duration = $meta->{duration};

	# sometimes we only get a 60s/mp3 sample
	if ($meta->{streamable} && $meta->{streamable} eq 'sample' && $contentType eq 'mp3') {
		$duration = 60;
	}

	$song->duration($duration);

	if ($length && $contentType eq 'flc') {
		$bitrate = $length*8 / $duration if $duration;
		$song->bitrate($bitrate) if $bitrate;
	}

	if ($client) {
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
	}

	Plugins::Qobuz::Reporting->startStreaming($client);

	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $class->crackUrl($url);
	$id ||= $url;

	my $meta;

	# grab metadata from backend if needed, otherwise use cached values
	if ($id && $client && $client->master->pluginData('fetchingMeta')) {
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] ) if $client;
		$meta = Plugins::Qobuz::API->getCachedFileInfo($id);
	}
	elsif ($id) {
		$client->master->pluginData( fetchingMeta => 1 ) if $client;

		$meta = Plugins::Qobuz::API->getTrackInfo(sub {
			$client->master->pluginData( fetchingMeta => 0 ) if $client;
		}, $id);
	}

	$meta ||= {};
	if ($meta->{mime_type} && $meta->{mime_type} =~ /(fla?c|mp)/) {
		$meta->{type} = $meta->{mime_type} =~ /fla?c/ ? 'flc' : 'mp3';
	}
	$meta->{type} ||= $class->getFormatForURL($url);
	$meta->{ct} = $meta->{type};
	$meta->{bitrate} = $meta->{type} eq 'mp3' ? MP3_BITRATE : 750_000;

	if ($meta->{type} ne 'mp3' && $client && $client->playingSong && $client->playingSong->track->url eq $url) {
		$meta->{bitrate} = $client->playingSong->bitrate if $client->playingSong->bitrate;
		$meta->{samplerate} = $client->playingSong->pluginData('samplerate');
		$meta->{samplesize} = $client->playingSong->pluginData('samplesize');
	}

	$meta->{bitrate} = sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $meta->{bitrate}/1000);

	if ($meta->{composer} && $prefs->get('showComposerWithArtist') && $meta->{artist} !~ /$meta->{composer}/) {
		$meta->{artist} .= ', ' . $meta->{composer};
	}

	if ($meta->{cover} && ref $meta->{cover}) {
		$meta->{cover} = Plugins::Qobuz::API::Common->getImageFromImagesHash($meta->{cover});
	}

	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack()->url;

	# Get next track
	my ($id, $format) = $class->crackUrl($url);

	Plugins::Qobuz::API->getFileInfo(sub {
		my $streamData = shift;

		if ($streamData) {
			$song->pluginData(mime => $streamData->{mime_type});

			$song->pluginData(samplesize => $streamData->{bit_depth});
			$song->pluginData(samplerate => $streamData->{sampling_rate});

			Plugins::Qobuz::API->getFileUrl(sub {
				$song->streamUrl(shift);
				$successCb->();
			}, $id, $format, $song->master);
			return;
		}

		$errorCb->('Failed to get next track', 'Qobuz');
	}, $id, $format);
}
sub crackUrl {
	my ($class, $url) = @_;

	return unless $url;

	my ($id, $format) = $url =~ m{^qobuz://(.+?)\.(mp3|flac)$};

	# compatibility with old urls without extension
	($id) = $url =~ m{^qobuz://([^\.]+)$} unless $id;
	($id) = $url =~ m{^https?://.*?eid=(\d+)} unless $id;

	return ($id, $format || Plugins::Qobuz::API::Common->getStreamingFormat($url));
}

sub audioScrobblerSource {
	# Scrobble as 'chosen by user' content
	return 'P';
}

1;
