package Plugins::Qobuz::ProtocolHandler;

# Handler for qobuz:// URLs

use strict;
use base qw(Slim::Player::Protocols::HTTPS);
use Scalar::Util qw(blessed);
use Text::Unidecode;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::Reporting;

use constant MP3_BITRATE => 320_000;
use constant CAN_FLAC_SEEK => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0 && UNIVERSAL::can('Slim::Utils::Scanner::Remote', 'parseFlacHeader'));

use constant PAGE_URL_REGEXP => qr{(?:open|play)\.qobuz\.com/(.+)/([a-z0-9]+)};
Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__) if Slim::Player::ProtocolHandlers->can('registerURLHandler');

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
#		bitrate => $mime =~ /flac/i ? 750_000 : MP3_BITRATE,
	} ) || return;

	${*$sock}{contentType} = $mime;

	return $sock;
}

sub canSeek { 1 }

sub getSeekDataByPosition {
	my $class = shift;
	$class->SUPER::getSeekDataByPosition(@_) if CAN_FLAC_SEEK;
}

sub getSeekData {
	my $class = shift;
	my ( $client, $song, $newtime ) = @_;

	my $url = $song->currentTrack()->url() || return;

	my ($id, $type) = $class->crackUrl($url);

	if ($type eq 'mp3' && !$song->bitrate()) {
		$song->bitrate(MP3_BITRATE);
	}

	return $class->SUPER::getSeekData(@_) if CAN_FLAC_SEEK;

	my $bitrate = $song->bitrate();

	return unless $bitrate;

	return {
		sourceStreamOffset => ( $bitrate * $newtime ) / 8,
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

	my ($type, $id) = $url =~ PAGE_URL_REGEXP;
	($type, $id) = $url =~ /^qobuz:(\w+):(\w+)$/ if !($type && $id);

	if ($type && $id) {
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

		Plugins::Qobuz::Plugin::getAPIHandler($client)->$getter(sub {
			my $response = shift || [];

			my $uris = [];

			if ($response && ref $response && $response->{tracks}) {
				$uris = {
					items => [
						map {
							Plugins::Qobuz::Plugin::_trackItem($client, $_);
						} @{$response->{tracks}->{items}}
					]
				};
			}

			$cb->($uris);
		}, $id);
	}
	else {
		$cb->([$url])
	}
}

# Optionally override replaygain to use the supplied gain value
sub trackGain {
	my ( $class, $client, $url ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("Url: $url");

 	my $rgmode = preferences('server')->client($client)->get('replayGainMode');

	if ( $rgmode == 0 ) {  # no replay gain
		return undef;
	}

	my $cache = Plugins::Qobuz::API::Common->getCache();
	my $gain = 0;
	my $peak = 0;
	my $netGain = 0;
	my $album;

	my ($id) = $class->crackUrl($url);
	main::DEBUGLOG && $log->is_debug && $log->debug("Id: $id");

	my $meta = $cache->get('trackInfo_' . $id);
	main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($meta));

	if (!$meta) {
		main::INFOLOG && $log->info("Get track info failed for url $url - id($id)");
	} elsif ($rgmode == 1   # track gain in use
			|| (!($album = $cache->get('album_with_tracks_' . $meta->{albumId})) # OR not in the cached favorites
				&& (!($album = $cache->get('albumInfo_' . $meta->{albumId})) 	 # ...AND (not in cached albums
					|| ref $meta->{genre} ne "") )  # ...OR the track info was not populated from an album)
			|| !defined $album->{replay_gain}) {    # OR album gain not specified (should not occur)
		$gain = ($rgmode == 2) ? 0 : $meta->{replay_gain};  # zero replay gain for non-album tracks if using album gain
		$peak = ($rgmode == 2) ? 0 : $meta->{replay_peak};  # ... otherwise, use the track gain
		main::INFOLOG && $log->info("Using gain value of $gain : $peak for track: " .  $meta->{title} );
	} else {  # album or smart gain
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($album));
		$gain = $album->{replay_gain} || 0;
		$peak = $album->{replay_peak} || 0;
		main::INFOLOG && $log->info("Using album gain value of $gain : $peak for track: " . $meta->{title} );
	}

	$netGain = Slim::Player::ReplayGain::preventClipping($gain, $peak);
	main::INFOLOG && $log->info("Net replay gain: $netGain");
	return $netGain;
}

sub canDirectStreamSong {
	my ( $class, $client, $song ) = @_;

	return $class->SUPER::canDirectStreamSong($client, $song) if CAN_FLAC_SEEK;

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
	my $offset = $song->seekdata() ? $song->seekdata()->{'timeOffset'} : 0;

	# sometimes we only get a 30s/mp3 sample
	if ($meta->{streamable} && $meta->{streamable} eq 'sample' && $contentType eq 'mp3') {
		$duration = 30;
	}

	$song->duration($duration);

	if ($length && $contentType eq 'flc') {
		$bitrate = $length*8 / ($duration - $offset) if $duration;
		$song->bitrate($bitrate) if $bitrate;
	}

	if ($client) {
		$client->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
	}

	$song->track->setAttributes($meta);  # This change allows replay gain to be done by LMS

	Plugins::Qobuz::Reporting->startStreaming($client);

	# title, bitrate, metaint, redir, type, length, body
	return (undef, $bitrate, 0, undef, $contentType, $length, undef);
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my ($id) = $class->crackUrl($url);
	$id ||= $url;

	my $meta;
	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);

	# grab metadata from backend if needed, otherwise use cached values
	if ($id && $client && $client->master->pluginData('fetchingMeta')) {
		Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		$meta = $api->getCachedFileInfo($id);
	}
	elsif ($id) {
		$client->master->pluginData( fetchingMeta => 1 ) if $client;

		$meta = $api->getTrackInfo(sub {
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

	if ($client && $client->playingSong && $client->playingSong->track->url eq $url) {
		$meta->{bitrate} = $client->playingSong->bitrate if $client->playingSong->bitrate;
		if ( my $track = $client->playingSong->currentTrack) {
			$meta->{samplerate} = $track->samplerate if $track->samplerate;
			$meta->{samplesize} = $track->samplesize if $track->samplesize;
		} else {
			$meta->{samplerate} = $client->playingSong->samplerate if $client->playingSong->samplerate;
			$meta->{samplesize} = $client->playingSong->samplesize if $client->playingSong->samplesize;
		}
	}

	$meta->{bitrate} = sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $meta->{bitrate}/1000);

	if ($meta->{composer} && $prefs->get('showComposerWithArtist') && $meta->{artist} !~ /$meta->{composer}/) {
		$meta->{artist} .= ', ' . $meta->{composer};
	}

	if ($meta->{cover} && ref $meta->{cover}) {
		$meta->{cover} = Plugins::Qobuz::API::Common->getImageFromImagesHash($meta->{cover});
	}

	$meta->{title} = Plugins::Qobuz::API::Common->addVersionToTitle($meta);

	# user pref is for enhanced classical music display, and we have a classical release (this is where playlist track titles is set up)
	if ( $meta->{isClassique} ) {
		# if the title doesn't already contain the work text
		if ( $meta->{work} && index($meta->{title},$meta->{work}) == -1 ) {
			# remove composer name from track title
			if ( $meta->{composer} ) {
				# full name
				$meta->{title} =~ s/\Q$meta->{composer}\E:\s*//;
				# surname only
				my $composerSurname = (split " ", $meta->{composer})[-1];
				$meta->{title} =~ s/\Q$composerSurname\E:\s*//;
			}

			my $simpleWork = Slim::Utils::Text::ignoreCaseArticles(unidecode($meta->{work}), 1);
			$simpleWork =~ s/\W//g;
			my $simpleTitle = Slim::Utils::Text::ignoreCaseArticles(unidecode($meta->{title}), 1);
			$simpleTitle =~ s/\W//g;
			if ( $simpleWork ne $simpleTitle ) {
				$meta->{title} =  $meta->{work} . string('COLON') . ' ' . $meta->{title};
			}
		}

		# Prepend composer surname to title unless it's at the beginning of the work/title (code above only strips out composer+COLON
		# and tracks exist where the composer name in the body of the title - we should still prepend composer to these.
		if ( $meta->{composer} ) {
			my $composerSurname = (split " ", $meta->{composer})[-1];
			if ( !($meta->{title} =~ /^\Q$meta->{composer}\E/ || $meta->{title} =~ /^\Q$composerSurname\E/) ) {
				$meta->{title} =  $composerSurname . string('COLON') . ' ' . $meta->{title};
			}
		}
	}

	if ( $prefs->get('parentalWarning') && $meta->{parental_warning} ) {
		$meta->{title} .= ' [E]';
	}

	if ( $prefs->get('showDiscs') ) {
		$meta->{album} = Slim::Music::Info::addDiscNumberToAlbumTitle($meta->{album},$meta->{media_number},$meta->{media_count});
	}

	# When the user is not browsing via album, genre is a map, not a simple string. Check for this and correct it.
	if ( ref $meta->{genre} ne "" ) {
		$meta->{genre} = $meta->{genre}->{name};
	}

	$meta->{tracknum} = $meta->{track_number};
	return $meta;
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack()->url;
	my $client = $song->master();

	# Get next track
	my ($id, $format) = $class->crackUrl($url);
	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);

	$api->getFileInfo(sub {
		my $streamData = shift;

		if ($streamData) {
			$song->pluginData(mime => $streamData->{mime_type});

			$song->pluginData(samplesize => $streamData->{bit_depth});
			$song->pluginData(samplerate => $streamData->{sampling_rate});

			$api->getFileUrl(sub {
				$song->streamUrl(shift);

				if (CAN_FLAC_SEEK && $format =~ /fla?c/i) {
					main::INFOLOG && $log->is_info && $log->info("Getting flac header information for: " . $song->streamUrl);
					my $http = Slim::Networking::Async::HTTP->new;
					$http->send_request( {
						request     => HTTP::Request->new( GET => $song->streamUrl ),
						onStream    => \&Slim::Utils::Scanner::Remote::parseFlacHeader,
						onError     => sub {
							my ($self, $error) = @_;
							$log->warn( "could not find $format header $error" );
							$successCb->();
						},
						passthrough => [ $song->track, { cb => $successCb }, $song->streamUrl ],
					} );
				} else {
					$successCb->();
				}
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
