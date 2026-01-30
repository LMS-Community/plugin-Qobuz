#Sven 2026-01-29 enhancements version 30.6.7
# 2025-09-16 v30.6.2 - _precacheAlbum
# 2025-10-16 - _precacheAlbum - albums of the week
# 2025-12-23 enhancements for managing users, if Material sends "user_id:xxx"

# $log->error(Data::Dump::dump( ));
package Plugins::Qobuz::API::Common;

use strict;
use Exporter::Lite;
use Time::Local qw( timelocal ); #Sven 2025-10-15 - _date2time()

our @EXPORT = qw(
	QOBUZ_BASE_URL QOBUZ_DEFAULT_EXPIRY QOBUZ_USER_DATA_EXPIRY QOBUZ_EDITORIAL_EXPIRY QOBUZ_DEFAULT_LIMIT QOBUZ_LIMIT QOBUZ_USERDATA_LIMIT
	QOBUZ_STREAMING_MP3 QOBUZ_STREAMING_FLAC QOBUZ_STREAMING_FLAC_HIRES QOBUZ_STREAMING_FLAC_HIRES2
	_precacheAlbum _precacheTracks precacheTrack isClassique
);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
#use Scalar::Util qw(blessed); # nur einfügen wenn blessed benötigt wird

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
my %genreList;
# Ein HASH der pro Player (Client) die aktuelle von Material mitgeschickte 'user_id' und die Qobuz 'userid' (UID) speichert. Ist sonst leer.
# Der Zugriff ist $controller->{$player->id}->{user_id} und $controller->{$player->id}->{userid}
my $controller = {}; 

initGenreMap();

$prefs->setChange(\&initGenreMap, 'classicalGenres');

sub init {
	return pack('H*', $_[2]) =~ /^(\d{9})([a-f0-9]{32})(\d{9})/i
}

sub initGenreMap {
   %genreList = map { $_ => 1 } split /\s*,\s*/, $prefs->get('classicalGenres');
}

sub getCache {
	return $cache ||= Slim::Utils::Cache->new('qobuz', 5);
}

sub getAccountList {
	return [ grep {
		$_->[0] && $_->[1]
	} map {[
		$_->{userdata}->{display_name} || $_->{userdata}->{login},
		$_->{userdata}->{id},
		$_->{dontimport},
		$_->{lmsuser} #Sven 2025-12-23
		
	]} sort {
		lc($a->{userdata}->{display_name} || $a->{userdata}->{login}) cmp lc($b->{userdata}->{display_name} || $b->{userdata}->{login});
	} values %{ $prefs->get('accounts') } ];
}

sub hasAccount {
	return scalar @{ getAccountList() } ? 1 : 0;
}

#Sven 2026-01-26
sub getAccountStatus {  
	my ($client, $params) = @_; # $client muss ein Player::Client Objekt sein, $params enthält den Parameter des API-Aufrufs

	my $accounts = getAccountList();
	my $count    = scalar @$accounts;
	my $select   = ($count > 1);

	if ( $count > 0) {
		my $clientid = $client->id;
		if (defined $params && exists $params->{user_id} ) {
			# 'user_id' existiert, wurde also mitgeschickt (macht aktuell nur Material)
			my $userId = $params->{user_id};
			my $ctrl   = $controller->{$clientid};
			$ctrl = $controller->{$clientid} = {} unless $ctrl;
			if ($select = ! ($ctrl->{user_id} && $ctrl->{user_id} eq $userId) ) { 
				# nachschauen ob es diese 'user_id' in der Accountliste gibt, wenn ja die zugehörige "Qobuz UID" abspeichern
				# diese bleibt solange gültig solange sie nicht geändert wird. Sei es durch Material oder durch Änderung der Accountliste.
				my $uid = '';
				foreach ( @$accounts ) { 
					if ( $_->[3] eq $userId ) { $uid = $_->[1]; last; }
				}
				if ($uid) {
					$ctrl->{userid}  = $uid;
					$ctrl->{user_id} = $userId;
					# $log->error('Set Controller-Id = ' . $clientid . '-' . $uid);
					# $uid wird später auch in Qobuz:Plugin:getAPIHandler() in den Prefs des Players gespeichert.
					$select = 0;
				}
			}
		}
		delete $controller->{$clientid} if $select; 
	}
	return { count => $count, accountSelect => $select };
}

#Sven 2026-01-12
sub getUserId {
	my ($class, $clientOrUserId) = @_;

	return $clientOrUserId unless ref $clientOrUserId;

	my $ctrl = $controller->{$clientOrUserId->id};
	if ($ctrl && $ctrl->{userid}) { return $ctrl->{userid}; }

	return $prefs->client($clientOrUserId)->get('userId');
}

#Sven 2026-01-12
sub getAccountData {
	my ($class, $clientOrUserId) = @_;

	my $accounts = $prefs->get('accounts') || return;

	return $accounts->{$class->getUserId($clientOrUserId)};
}

sub getSomeUserId {
	my ($class, $clientOrUserId) = @_;

	my $userId = $class->getUserId($clientOrUserId);

	($userId) = map { $_->[1] } @{ $class->getAccountList } if $userId;

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

#Sven 2025-10-16 v30.6.3 
sub filterPlayables {
	my ($class, $items, $isEnhApi) = @_;

	return $items if $prefs->get('playSamples');
	
	if (defined $isEnhApi && $isEnhApi) {
		return [ grep {
			$_->{rights}->{streamable};  # allow all tracks and streamable albums
		} @$items ];
	}
	else {
		return [ grep {
			!$_->{released_at} || $_->{streamable};  # allow all tracks and streamable albums
		} @$items ];
	}	
}

#Sven 2025-09-16, 2025-10-16 v30.6.3 
sub _precacheAlbum {
	my ($albums) = @_;

	return unless ($albums && ref $albums eq 'ARRAY' && scalar @$albums); #Sven 2025-10-24;
	
	my $album = @$albums[0];
	my $isEnhApi = (exists $album->{dates}); #Sven 2025-10-15 - meta format of new enhanced API command

	$albums = __PACKAGE__->filterPlayables($albums, $isEnhApi);

	foreach $album (@$albums) {
		$album->{genrePath} = $album->{genre}->{path}; #Sven 2025-09-16 used for genre filter
		$album->{genre} = $album->{genre}->{name};
		$album->{image} = __PACKAGE__->getImageFromImagesHash($album->{image}) || '';
		unless ($isEnhApi) { 
			foreach (qw(composer articles article_ids catchline
				# maximum_bit_depth maximum_channel_count maximum_sampling_rate maximum_technical_specifications
				popularity previewable qobuz_id sampleable slug streamable_at subtitle created_at
				product_type product_url purchasable purchasable_at relative_url release_date_download release_date_original
				product_sales_factors_monthly product_sales_factors_weekly product_sales_factors_yearly))
				{ delete $album->{$_}; }
		} 
		else { #Sven 2025-10-15 - album meta format of new enhanced API command
			my $artist = $album->{artist};
			$artist = @{$album->{artists}}[0] unless ($artist);	
			if (ref $artist->{name} eq 'HASH') {
				$artist->{name} = $artist->{name}->{display};
				#$artist->{roles} = ["main-artist"];
			}
			$album->{artist} = $artist; # @{$album->{artists}}[0];
			$album->{tracks_count} = $album->{track_count};
			$album->{released_at} = _date2time($album->{dates}->{original});
			$album->{release_date_stream} = $album->{dates}->{stream};
			$album->{hires_streamable} = $album->{rights}->{hires_streamable};
			$album->{streamable} = $album->{rights}->{streamable};
			foreach (qw(audio_info articles dates rights track_count)) 
				{ delete $album->{$_}; }
		}

		my $albumInfo = {
			title  => $album->{title},
			id     => $album->{id},
			artist => $album->{artist},
			artists => $album->{artists},
			image  => $album->{image},
			year   => substr($album->{release_date_stream},0,4),
			goodies=> $album->{goodies},
			genre  => $album->{genre},
			genres_list => $album->{genres_list},
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
		} @{$album->{tracks}->{items}} ]) if (defined $album->{tracks}->{items}); #Sven 2025-10-17 

		if (defined $albumInfo->{replay_gain}) {
			$album->{replay_gain} = $albumInfo->{replay_gain};
			$album->{replay_peak} = $albumInfo->{replay_peak};
			$cache->set('albumInfo_' . $albumInfo->{id}, $albumInfo, QOBUZ_DEFAULT_EXPIRY);
		}
		elsif (my $cachedAlbumInfo = $cache->get('albumInfo_' . $album->{id})) {
			if (!ref $cachedAlbumInfo) {
				$cache->remove('albumInfo_' . $album->{id});
			}
			elsif (defined $cachedAlbumInfo->{replay_gain}) {
				$album->{replay_gain} = $cachedAlbumInfo->{replay_gain};
			}
		}
		else {
			$cache->set('albumInfo_' . $albumInfo->{id}, $albumInfo, QOBUZ_DEFAULT_EXPIRY);
		}
	}

	return $albums;
}

#Sven 2025-10-24 
sub _date2time { # "YYYY-MM-DD"
	my ($date) = @_;
	
	my ($year, $month, $day) = split /-/, $date;
	
	# Create Unix time (Seconds sinse 1970-01-01 00:00:00 UTC)
	timelocal(0, 0, 0, $day, $month - 1, $year); # In der aktuellen Perl Version darf nicht 1900 von $year abgezogen werden
}

# Sven 2025-10-23
sub _precacheTracks {
	my ($tracks) = @_;

	return [] unless ($tracks && ref $tracks eq 'ARRAY' && scalar @$tracks); #Sven 2025-10-24
	
	my $isEnhApi = (exists @$tracks[0]->{rights}); #Sven 2025-10-23 - meta format of new enhanced API command

	$tracks = __PACKAGE__->filterPlayables($tracks, $isEnhApi);

	foreach my $track (@$tracks) {
		if ($isEnhApi) { #Sven 2025-10-23 - track meta format of the new enhanced API commands
			my $artist = $track->{artist};
			$artist = @{$track->{artists}}[0] unless ($artist);	
			if (ref $artist->{name} eq 'HASH') {
				$artist->{name} = $artist->{name}->{display};
				$artist->{roles} = ["main-artist"];
			}
			$track->{album}->{artist} = $artist;
			$track->{artist} = $artist->{name};
			$track->{artistId} = $artist->{id};

			$artist = $track->{composer};
			if ($artist && ref $artist->{name} eq 'HASH') {
				$artist->{name} = $artist->{name}->{display};
			}

			$track->{track_number} = $track->{physical_support}->{track_number};
			$track->{media_number} = $track->{physical_support}->{media_number};
			$track->{hires_streamable} = $track->{rights}->{hires_streamable};
			$track->{streamable} = $track->{rights}->{streamable};
			foreach (qw(artists physical_support rights)) { #Sven 2025-10-24 
				delete $track->{$_};
			}
		}
		else { #Sven 2025-10-24
			foreach (qw(article_ids copyright downloadable isrc previewable purchasable purchasable_at)) {  
				delete $track->{$_};
			}
		}
		precacheTrack($track);
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
	my ($artistNames, $artistIds);
	foreach ( $class->getMainArtists($album) ) {
		push @$artistNames, $_->{name};
		push @$artistIds, $_->{id};
	}
	Plugins::Qobuz::API::Common->removeArtistsIfNotOnTrack($track, $artistNames, $artistIds);
	if ($track->{performer} && $class->trackPerformerIsMainArtist($track) ) {
		push @$artistNames, $track->{performer}->{name};
		push @$artistIds, $track->{performer}->{id};
	}
	
	my $meta = {
		title    => $track->{title} || $track->{id},
		album    => $album->{title} || '',
		albumId  => $album->{id},
		artist   => $artistNames->[0],
		artistId => $artistIds->[0],
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

sub getMainArtists {
	my ($class, $album) = @_;

	my @artistList = ();
	my $artistName;

	if (ref $album->{artist}) {
		if ( $album->{artist}->{name} !~ /^\s*various\s*artists\s*$/i ) {
			push @artistList, $album->{artist};  # always include the primary artist
			$artistName = lc($album->{artist}->{name});
		}
	}
	if (ref $album->{artists} && scalar @{$album->{artists}}) {
		for my $artist ( @{$album->{artists}} ) {  # get additional main artists, if any
			if (grep(/main-artist/, @{$artist->{roles}}) && (lc($artist->{name}) ne $artistName)) {
				push @artistList, $artist;
			}
		}
	}
	return @artistList;
}

sub trackPerformerIsMainArtist {
	my ($class, $track) = @_;

	if ($track->{performers}) {
		my $pname = $track->{performer}->{name};
		$pname =~ s/\s+$//;   # trim the trailing white space
		return $track->{performers} =~ m/\Q$pname\E([^\-]*)(Main\ ?Artist)/i;
	}
	else {
		return 0;
	}
}

sub removeArtistsIfNotOnTrack {
	my ($class, $track, $artists, $artistIds) = @_;

	if ( ( !$track->{album}->{genres_list} || grep(/Classique/,@{$track->{album}->{genres_list}}) ) && $artists && scalar @$artists ) {
		my $mainArtist = $artists->[0];
		my $mainArtistId = $artistIds->[0] if $artistIds;
		for (my $i = 0; $i < @$artists; $i++) {
			my $artist = $artists->[$i];
			if ( $track->{performers} !~ /\Q$artist\E/i ) {
				splice(@$artists, $i, 1);
				splice(@$artistIds, $i, 1) if $artistIds;
				$i--; # Adjust index after removal
			}
		}
		# if all artists were removed, put back the main artist
		if (!scalar @$artists) {
			$artists->[0] = $mainArtist;
			$artistIds->[0] = $mainArtistId if $mainArtistId;
		}
	}
	return;
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

#Sven 2025-11-04
sub getPlaylistImage {
	my ($class, $playlist) = @_;

	my $image;

	#Sven new image format in new api commands
	foreach ('image', 'images') {
		if ($playlist->{$_} && ref $playlist->{$_} eq 'HASH' && ($image = $playlist->{$_}->{rectangle})) {
			return @$image[0] if (ref $image eq 'ARRAY');
			return $image;
		}
	}

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

sub isClassique {
	my $album = shift;

	# Is this a classical release or has the user added the genre to their custom classical list?
	return ( $album->{genres_list} && grep(/Classique/,@{$album->{genres_list}}) ) || $genreList{$album->{genre}};
}

1;
