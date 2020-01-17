package Plugins::Qobuz::Importer;

use strict;

use Date::Parse qw(str2time);
# use Digest::MD5 qw(md5_hex);

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);

use Plugins::Qobuz::API::Common;

my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz');

my $cache = Plugins::Qobuz::API::Common->getCache();

sub initPlugin {
	my $class = shift;

	# return unless $prefs->get('integrateWithMyMusic');

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	my $aid;
	if ($pluginData && ref $pluginData) {
		$aid = $pluginData->{aid};
	}

	eval {
		require Plugins::Qobuz::API::Sync;
		Plugins::Qobuz::API::Sync->init($aid);
	};

	if ($@) {
		$log->error($@);
		$log->warn("Please update your LMS to be able to use online library integration in My Music");
		return;
	}

	Slim::Music::Import->addImporter($class, {
		'type'         => 'file',
		'weight'       => 200,
		'use'          => 1,
		'playlistOnly' => 1,
		'onlineLibraryOnly' => 1,
	});

	return 1;
}

sub startScan {
	my $class = shift;

	my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

	if (!$playlistsOnly) {
		my $progress = Slim::Utils::Progress->new({
			'type'  => 'importer',
			'name'  => 'plugin_qobuz_albums',
			'total' => 1,
			'every' => 1,
		});

		my @missingAlbums;

		main::INFOLOG && $log->is_info && $log->info("Reading albums...");
		$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_ALBUMS'));

		my ($albums, $libraryMeta) = Plugins::Qobuz::API::Sync->myAlbums();

		$cache->set('latest_album_update', _libraryMetaId($libraryMeta), 86400);
		
		$progress->total(scalar @$albums + 2);

		foreach my $album (@$albums) {
			my $album = Plugins::Qobuz::API::Sync->getAlbum($album->{id});

# warn Data::Dump::dump($tracks);
			_storeTracks($album, $album->{tracks}->{items});
		}
	}

};


# This code is not run in the scanner, but in LMS
sub needsUpdate {
	my ($class, $cb) = @_;

	require Async::Util;
	require Plugins::Qobuz::API;

	my $timestamp = time();

	my @workers = (
		sub {
			my ($result, $acb) = @_;

			# don't run any further test in the queue if we already have a result
			return $acb->($result) if $result;

		# 	my $snapshotIds = $cache->get('spotty_snapshot_ids' . $accountId);

		# 	my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
		# 	$api->playlists(sub {
		# 		my ($playlists) = @_;

				my $needUpdate;
		# 		for my $playlist (@$playlists) {
		# 			my $snapshotId = $snapshotIds->{$playlist->{id}};
		# 			# we need an update if
		# 			# - we haven't a snapshot ID for this playlist, OR
		# 			# - the snapshot ID doesn't match, OR
		# 			# - the playlist is Spotify generated and older than a day
		# 			if ( !$snapshotId || ($snapshotId =~ /^\d{10}$/ ? $snapshotId < $timestamp : $snapshotId ne $playlist->{snapshot_id}) ) {
		# 				$needUpdate = 1;
		# 				last;
		# 			}
		# 		}

				$acb->($needUpdate);
		# 	});
		}, sub {
			my ($result, $acb) = @_;

			# don't run any further test in the queue if we already have a result
			return $acb->($result) if $result;

			my $lastUpdateData = $cache->get('latest_album_update') || '';

			Plugins::Qobuz::API->myAlbumsMeta(sub {
				$acb->(_libraryMetaId($_[0]) eq $lastUpdateData ? 0 : 1);
			});
		}
	);

	if (scalar @workers) {
		Async::Util::achain(
			input => undef,
			steps => \@workers,
			cb    => sub {
				my ($result, $error) = @_;
				$cb->( ($result && !$error) ? 1 : 0 );
			}
		);
	}
	else {
		$cb->();
	}
}

sub _libraryMetaId {
	my $libraryMeta = $_[0];
	return ($libraryMeta->{total} || '') . '|' . ($libraryMeta->{lastAdded} || '');
}

sub _storeTracks {
	my ($album, $tracks, $libraryId) = @_;

	return unless $tracks && ref $tracks;

	my $dbh = Slim::Schema->dbh();
	my $sth = $dbh->prepare_cached("INSERT OR IGNORE INTO library_track (library, track) VALUES (?, ?)") if $libraryId;
	my $c = 0;

	# my $splitChar = substr(preferences('server')->get('splitList'), 0, 1) || ' ';

	foreach my $track (@$tracks) {
		# my $item = $libraryCache->get($track->{uri}) || $track;
		my $item = $track;

		my $artist = $album->{artist}->{name};
		# TODO my $composer
		# my $extId = join(',', map { $_->{uri} } @{ $item->{album}->{artists} || [$item->{artists}->[0]] });
		my $url = Plugins::Qobuz::API::Common->getUrl($item);

		my $trackObj = Slim::Schema->updateOrCreate({
			url        => $url,
			integrateRemote => 1,
			attributes => {
				TITLE        => $item->{title},
				ARTIST       => $artist,
				ARTIST_EXTID => $album->{artist}->{id},
				# TRACKARTIST  => join($splitChar, map { $_->{name} } @{ $item->{artists} }),
				ALBUM        => $album->{title},
				ALBUM_EXTID  => $album->{id},
				TRACKNUM     => $item->{track_number},
				GENRE        => $album->{genre}->{name},
				DISC         => $item->{media_number},
				DISCC        => $item->{tracks_count},
				SECS         => $item->{duration},
				YEAR         => substr($album->{release_date_original}, 0, 4),
				COVER        => $album->{image}->{large} || $album->{image}->{small} || $album->{image}->{thumbnail},
				AUDIO        => 1,
				EXTID        => $item->{id},
				# COMPILATION  => $item->{album}->{album_type} eq 'compilation',
				TIMESTAMP    => str2time($album->{favorited_at} || 0),
				CONTENT_TYPE => Slim::Music::Info::typeFromPath($url),
			},
		});

		if ($libraryId) {
			$sth->execute($libraryId, $trackObj->id);
		}

		if (!main::SCANNER && ++$c % 20 == 0) {
			main::idle();
		}
	}

	main::idle() if !main::SCANNER;
}


1;
