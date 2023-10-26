package Plugins::Qobuz::Importer;

use strict;

# can't "use base ()", as this would fail in LMS 7
BEGIN {
	eval {
		require Slim::Plugin::OnlineLibraryBase;
		our @ISA = qw(Slim::Plugin::OnlineLibraryBase);
	};
}

use List::Util qw(max);

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);

use Plugins::Qobuz::API::Common;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my $cache = Plugins::Qobuz::API::Common->getCache();

sub initPlugin {
	my $class = shift;

	if (!CAN_IMPORTER) {
		$log->warn('The library importer feature requires at least Logitech Media Server 8.');
		return;
	}

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class) || return;

	my $aid = $pluginData->{aid};

	require Plugins::Qobuz::API::Sync;
	Plugins::Qobuz::API::Sync->init($aid);

	$class->SUPER::initPlugin(@_)
}

sub startScan { if (main::SCANNER) {
	my $class = shift;

	my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

	$class->initOnlineTracksTable();

	if (!$playlistsOnly) {
		$class->scanAlbums();
		$class->scanArtists();
	}

	if (!$class->_ignorePlaylists) {
		$class->scanPlaylists();
	}

	$class->deleteRemovedTracks();
	$cache->set('last_update', time(), '1y');

	Slim::Music::Import->endImporter($class);
} };

sub scanAlbums {
	my ($class) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_qobuz_albums',
		'total' => 1,
		'every' => 1,
	});

	my %missingAlbums;

	main::INFOLOG && $log->is_info && $log->info("Reading albums...");
	$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_ALBUMS'));

	my $albums = Plugins::Qobuz::API::Sync->myAlbums($prefs->get('dontImportPurchases'));
	$progress->total(scalar @$albums);

	foreach my $album (@$albums) {
		my $albumDetails = $cache->get('album_with_tracks_' . $album->{id});

		if ($albumDetails && $albumDetails->{tracks} && ref $albumDetails->{tracks} && $albumDetails->{tracks}->{items}) {
			$progress->update($album->{title});
			$class->storeTracks([
				map { _prepareTrack($albumDetails, $_) } @{ $albumDetails->{tracks}->{items} }
			]);

			main::SCANNER && Slim::Schema->forceCommit;
		}
		else {
			$missingAlbums{$album->{id}} = $album->{favorited_at} || $album->{purchased_at};
		}
	}

	while ( my ($albumId, $timestamp) = each %missingAlbums ) {
		my $album = Plugins::Qobuz::API::Sync->getAlbum($albumId);
		$progress->update($album->{title});

		$album->{favorited_at} = $timestamp;
		$cache->set('album_with_tracks_' . $albumId, $album, time() + 86400 * 90);

		$class->storeTracks([
			map { _prepareTrack($album, $_) } @{ $album->{tracks}->{items} }
		]);

		main::SCANNER && Slim::Schema->forceCommit;
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub scanArtists {
	my ($class) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_qobuz_artists',
		'total' => 1,
		'every' => 1,
	});

	# backwards compatibility for 8.1 and older...
	my $contributorNameNormalizer;
	if ($class->can('normalizeContributorName')) {
		$contributorNameNormalizer = sub {
			$class->normalizeContributorName($_[0]);
		};
	}
	else {
		$contributorNameNormalizer = sub { $_[0] };
	}

	main::INFOLOG && $log->is_info && $log->info("Reading artists...");
	$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_ARTISTS'));

	my $artists = Plugins::Qobuz::API::Sync->myArtists();

	$progress->total($progress->total + scalar @$artists);

	foreach my $artist (@$artists) {
		my $name = $artist->{name};

		$progress->update($name);
		main::SCANNER && Slim::Schema->forceCommit;

		Slim::Schema::Contributor->add({
			'artist' => $contributorNameNormalizer->($name),
			'extid'  => 'qobuz:artist:' . $artist->{id},
		});
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub scanPlaylists {
	my ($class) = @_;

	my $dbh = Slim::Schema->dbh();

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_qobuz_playlists',
		'total' => 2,
		'every' => 1,
	});

	main::INFOLOG && $log->is_info && $log->info("Removing playlists...");
	$progress->update(string('PLAYLIST_DELETED_PROGRESS'));
	my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'qobuz://%.qbz' AND content_type = 'ssp'");
	$deletePlaylists_sth->execute();

	$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_PLAYLISTS'));

	main::INFOLOG && $log->is_info && $log->info("Reading playlists...");
	my $playlists = Plugins::Qobuz::API::Sync->myPlaylists();

	$progress->total(scalar @$playlists);

	$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_TRACKS'));
	my %tracks;
	my $c = my $latestPlaylistUpdate = 0;

	main::INFOLOG && $log->is_info && $log->info("Getting playlist tracks...");

	my $insertTrackInTempTable_sth = $dbh->prepare_cached("INSERT OR IGNORE INTO online_tracks (url) VALUES (?)") if main::SCANNER && !$main::wipe;

	# we need to get the tracks first
	my $prefix = 'Qobuz' . string('COLON') . ' ';
	foreach my $playlist (@{$playlists || []}) {
		next unless $playlist->{id} && $playlist->{duration};

		$latestPlaylistUpdate = max($latestPlaylistUpdate, $playlist->{updated_at});

		$progress->update($playlist->{name});
		main::SCANNER && Slim::Schema->forceCommit;

		my $url = 'qobuz://' . $playlist->{id} . '.qbz';

		my $playlistObj = Slim::Schema->updateOrCreate({
			url        => $url,
			playlist   => 1,
			integrateRemote => 1,
			attributes => {
				TITLE        => $prefix . $playlist->{name},
				COVER        => Plugins::Qobuz::API::Common->getPlaylistImage($playlist),
				AUDIO        => 1,
				EXTID        => $url,
				CONTENT_TYPE => 'ssp'
			},
		});

		my @trackIDs = map { Plugins::Qobuz::API::Common->getUrl($_) } @{Plugins::Qobuz::API::Sync->getPlaylistTracks($playlist->{id})};
		$cache->set('playlist_tracks' . $playlist->{id}, \@trackIDs, time() + 86400 * 360);

		$playlistObj->setTracks(\@trackIDs) if $playlistObj && scalar @trackIDs;
		$insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
	}

	main::INFOLOG && $log->is_info && $log->info("Done, finally!");

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub getArtistPicture { if (main::SCANNER) {
	my ($class, $id) = @_;

	my $artist = Plugins::Qobuz::API::Sync->getArtist($id);
	return ($artist && ref $artist) ? $artist->{picture} : '';
} }

sub trackUriPrefix { 'qobuz://' }

# This code is not run in the scanner, but in LMS
sub needsUpdate {
	my ($class, $cb) = @_;

	require Plugins::Qobuz::API;

	Plugins::Qobuz::API->updateUserdata(sub {
		my $result = shift;

		my $needUpdate;

		if ($result && ref $result eq 'HASH' && $result->{last_update} && ref $result->{last_update} eq 'HASH') {
			my $timestamps = Storable::dclone($result->{last_update});
			delete $timestamps->{playlist} if $class->_ignorePlaylists;

			$needUpdate = $cache->get('last_update') < max(values %$timestamps);
		}

		$cb->($needUpdate);
	});
}

sub _ignorePlaylists {
	my $class = shift;
	return $class->can('ignorePlaylists') && $class->ignorePlaylists;
}

sub _prepareTrack {
	my ($album, $track) = @_;

	my $url = Plugins::Qobuz::API::Common->getUrl($track) || return;
	my $ct  = Slim::Music::Info::typeFromPath($url);

	my ($artist, $artistId);
	if (ref $album->{artists}) {
		($artist, $artistId) = map { $_->{name}, $_->{id} } grep {
			$_->{roles} && grep(/main-artist/, @{$_->{roles}})
		} @{$album->{artists}};
	}

	my $attributes = {
		url          => $url,
		TITLE        => Plugins::Qobuz::API::Common->addVersionToTitle($track),
		ARTIST       => $artist || $album->{artist}->{name},
		ARTIST_EXTID => 'qobuz:artist:' . ($artistId || $album->{artist}->{id}),
		ALBUM        => $album->{title},
		ALBUM_EXTID  => 'qobuz:album:' . $album->{id},
		TRACKNUM     => $track->{track_number},
		GENRE        => $album->{genre},
		SECS         => $track->{duration},
		YEAR         => substr($album->{release_date_stream},0,4),
		COVER        => $album->{image},
		AUDIO        => 1,
		EXTID        => $url,
		# COMPILATION  => $track->{album}->{album_type} eq 'compilation',
		TIMESTAMP    => $album->{favorited_at} || $album->{purchased_at},
		CONTENT_TYPE => $ct,
		SAMPLERATE   => $track->{maximum_sampling_rate} * 1000,
		SAMPLESIZE   => $track->{maximum_bit_depth},
		CHANNELS     => $track->{maximum_channel_count},
		LOSSLESS     => $ct eq 'flc',
		RELEASETYPE  => $album->{release_type} =~ /^[a-z]+$/ ? ucfirst($album->{release_type}) : $album->{release_type},
	};

	if ($album->{media_count} > 1) {
		$attributes->{DISC} = $track->{media_number};
		$attributes->{DISCC} = $album->{media_count};
	}

	if ($track->{composer}) {
		$attributes->{COMPOSER} = $track->{composer}->{name};
	}

	if ($track->{performer} && $track->{performer}->{name} ne $album->{artist}->{name}) {
		$attributes->{TRACKARTIST} = $track->{performer}->{name};
	}

	if ($track->{audio_info}) {
		$attributes->{REPLAYGAIN_TRACK_GAIN} = $track->{audio_info}->{replaygain_track_gain};
	}

	return $attributes;
}

1;
