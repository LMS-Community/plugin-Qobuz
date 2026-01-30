#Sven 2025-12-30 enhancements version 30.6.7
#Sven 2025-10-29 - startStreaming() uses now function _post()
#Sven 2025-10-29 - endStreaming() uses now function _post(), endStreaming() is currently only sent when the next track starts playing. That's probably not how Qobuz intended it to work.
package Plugins::Qobuz::Reporting;

use strict;
use JSON::XS::VersionOneAndTwo;
use List::Util qw(max);
use Tie::Cache::LRU::Expires;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API;
use Plugins::Qobuz::API::Common;
use Plugins::Qobuz::ProtocolHandler;

# don't report the same track twice
tie my %reportedTracks, 'Tie::Cache::LRU::Expires', EXPIRES => 60, ENTRIES => 10;

my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

#Sven 2025-10-29
sub startStreaming {
	my ($class, $client, $cb) = @_;

	if (!$client) {
		$cb->() if $cb;
		return;
	}

	$client = $client->master;

	$class->endStreaming($client) if $client->pluginData('streamingEvent');

	my ($url, $track_id, $format, $duration) = _getTrackInfo($client);

	# we'd still have the pluginData if we were still playing the same song - no need to report
	if ( !($url && $track_id) || $reportedTracks{"start_$track_id"} || $client->pluginData('streamingEvent') ) {
		$cb->() if $cb;
		return;
	}

	$reportedTracks{"start_$track_id"} = 1;

	$format ||= Plugins::Qobuz::ProtocolHandler->getFormatForURL($url);
	my $devicedata = Plugins::Qobuz::API::Common->getDevicedata($client);
	my $credentials = Plugins::Qobuz::API::Common->getCredentials($client) || {};

	my $format_id = QOBUZ_STREAMING_MP3;
	if ($format ne 'mp3') {
		$format_id = ($prefs->get('preferredFormat') || 0) < QOBUZ_STREAMING_FLAC_HIRES
			? QOBUZ_STREAMING_MP3
			: QOBUZ_STREAMING_FLAC_HIRES;
	}

	my $event = {
		user_id  => Plugins::Qobuz::API::Common->getUserdata($client, 'id'),
		duration => 0,
		'date'   => time(),
		online   => JSON::XS::true,
		intent   => 'streaming',
		sample   => JSON::XS::false,
		device_id=> $devicedata->{id},
		track_id => $track_id,
		'local'  => JSON::XS::false,
		credential_id => $credentials->{id},
		format_id=> $format_id,
	};

	my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);

	$api->checkPurchase('track', $track_id, sub {
		$event->{purchase} = $_[0] ? JSON::XS::true : JSON::XS::false;

		#Sven
		$api->_post('track/reportStreamingStart', sub {
			$event->{duration} = $duration || 0;
			$client->pluginData( streamingEvent => $event );
			$cb->(@_) if $cb;
		}, { _use_token => 1, _contentType => 'application/x-www-form-urlencoded', data => 'event=[' . to_json($event) . ']' });
	});
}

#Sven 2025-10-29 - It's currently only sent when the next track starts playing. That's probably not how Qobuz intended it to work.
sub endStreaming {
	my ($class, $client, $cb) = @_;

	if (!$client) {
		$log->error("No client found");
		$cb->() if $cb;
		return;
	}

	$client = $client->master;

	my $event = $client->pluginData('streamingEvent');

	if ( !($event && ref $event && scalar keys %$event) ) {
		$log->error("No event data found");
		$cb->() if $cb;
		return;
	}

	if (my $track_id = $event->{track_id}) {
		if ($reportedTracks{"end_$track_id"}) {
			$log->info("Reported event before");
			$cb->() if $cb;
			return;
		}

		$reportedTracks{"end_$track_id"} = 1;
	}

	my ($url, $track_id) = _getTrackInfo($client);
	if ($track_id == $event->{track_id}) {
		main::INFOLOG && $log->is_info && $log->info("We're still streaming the same song, don't report streaming end.");
		$cb->() if $cb;
		return;
	}

	$event = Storable::dclone($event);

	# Delete streaming information. We don't want to report twice.
	$client->pluginData( streamingEvent => '' );

	# delete $event->{intent};
	$event->{'date'} = time();
	$event->{duration} = max($event->{duration}, time() - $event->{'date'});

	Plugins::Qobuz::Plugin::getAPIHandler($client)->_post('track/reportStreamingEnd', $cb, { _use_token => 1, data => 'event=[' . to_json($event) . ']' }); #Sven
}

sub _getTrackInfo {
	my ($client) = @_;

	return unless $client && $client->playingSong;

	my $url = $client->streamingSong->track->url || return;

	my ($track_id, $format) = Plugins::Qobuz::ProtocolHandler->crackUrl($url);

	return ($url, $track_id, $format, $client->playingSong->duration);
}

1;