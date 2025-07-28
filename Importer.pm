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
my $someUserId = Plugins::Qobuz::API::Common->getSomeUserId();

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

	my $accounts = _enabledAccounts();

	if (scalar @$accounts) {
		my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();

		$class->initOnlineTracksTable();

		if (!$playlistsOnly) {
			$class->scanAlbums($accounts);
			$class->scanArtists($accounts);
		}

		if (!$class->_ignorePlaylists) {
			$class->scanPlaylists($accounts);
		}

		$class->deleteRemovedTracks();
		$cache->set('last_update', time(), '1y');
	}

	Slim::Music::Import->endImporter($class);
} };

sub _enabledAccounts {
	my $accounts = [ grep {
		!$_->[2];
	} @{Plugins::Qobuz::API::Common->getAccountList()} ];
}

sub scanAlbums {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_qobuz_albums',
		'total' => 1,
		'every' => 1,
	});

	foreach my $account (@$accounts) {
		my %missingAlbums;
		my $accountName = $account->[0] || '';

		main::INFOLOG && $log->is_info && $log->info("Reading albums... " . $accountName);
		$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_ALBUMS', $accountName));

		# TODO make dontImportPurchases per account
		my $albums = Plugins::Qobuz::API::Sync->myAlbums($account->[1], $prefs->get('dontImportPurchases'));
		$progress->total(scalar @$albums);

		foreach my $album (@$albums) {
			my $albumDetails = $cache->get('album_with_tracks_' . $album->{id});

			if ($albumDetails && ref $albumDetails && $albumDetails->{tracks} && ref $albumDetails->{tracks} && $albumDetails->{tracks}->{items}) {
				$progress->update($album->{title});

				my $albumArtists = {
					required => 0,
					ids      => undef,
					names    => undef,
				};
				my $attributes = [map { _prepareTrack($albumDetails, $_, $albumArtists) } @{ $albumDetails->{tracks}->{items} }];
				_checkAlbumArtists($attributes, $albumArtists);
				$class->storeTracks($attributes, undef, $accountName);

				main::SCANNER && Slim::Schema->forceCommit;
			}
			else {
				$missingAlbums{$album->{id}} = $album->{favorited_at} || $album->{purchased_at};
			}
		}

		while ( my ($albumId, $timestamp) = each %missingAlbums ) {
			my $album = Plugins::Qobuz::API::Sync->getAlbum($account->[1], $albumId);
			$progress->update($album->{title});

			$album->{favorited_at} = $timestamp;
			$cache->set('album_with_tracks_' . $albumId, $album, time() + 86400 * 90);

			my $albumArtists = {
				required => 0,
				ids      => undef,
				names    => undef,
			};
			my $attributes = [map { _prepareTrack($album, $_, $albumArtists) } @{ $album->{tracks}->{items} }];
			_checkAlbumArtists($attributes, $albumArtists);
			$class->storeTracks($attributes, undef, $accountName);

			main::SCANNER && Slim::Schema->forceCommit;
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub scanArtists {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_qobuz_artists',
		'total' => 1,
		'every' => 1,
	});

	foreach my $account (@$accounts) {
		main::INFOLOG && $log->is_info && $log->info("Reading artists... " . $account->[0]);
		$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_ARTISTS', $account->[0]));

		my $artists = Plugins::Qobuz::API::Sync->myArtists($account->[1]);

		$progress->total($progress->total + scalar @$artists);

		foreach my $artist (@$artists) {
			my $name = $artist->{name};

			$progress->update($name);
			main::SCANNER && Slim::Schema->forceCommit;

			Slim::Schema::Contributor->add({
				'artist' => $class->normalizeContributorName($name),
				'extid'  => 'qobuz:artist:' . $artist->{id},
			});
		}
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub scanPlaylists {
	my ($class, $accounts) = @_;

	my $dbh = Slim::Schema->dbh();

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_qobuz_playlists',
		'total' => 2,
		'every' => 1,
	});

	foreach my $account (@$accounts) {
		main::INFOLOG && $log->is_info && $log->info("Removing playlists... " . $account->[0]);
		$progress->update(string('PLAYLIST_DELETED_PROGRESS'));
		my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'qobuz://%.qbz' AND content_type = 'ssp'");
		$deletePlaylists_sth->execute();

		$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_PLAYLISTS', $account->[0]));

		main::INFOLOG && $log->is_info && $log->info("Reading playlists... " . $account->[0]);
		my $playlists = Plugins::Qobuz::API::Sync->myPlaylists($account->[1]);

		$progress->total(scalar @$playlists);

		$progress->update(string('PLUGIN_QOBUZ_PROGRESS_READ_TRACKS', $account->[0]));
		my %tracks;
		my $c = my $latestPlaylistUpdate = 0;

		main::INFOLOG && $log->is_info && $log->info("Getting playlist tracks... " . $account->[0]);

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

			my @trackIDs = map { Plugins::Qobuz::API::Common->getUrl(undef, $_) } @{Plugins::Qobuz::API::Sync->getPlaylistTracks($account->[1], $playlist->{id})};
			$cache->set('playlist_tracks' . $playlist->{id}, \@trackIDs, time() + 86400 * 360);

			$playlistObj->setTracks(\@trackIDs) if $playlistObj && scalar @trackIDs;
			$insertTrackInTempTable_sth && $insertTrackInTempTable_sth->execute($url);
		}

		main::INFOLOG && $log->is_info && $log->info("Done, finally! " . $account->[0]);
	}

	$progress->final();
	main::SCANNER && Slim::Schema->forceCommit;
}

sub getArtistPicture { if (main::SCANNER) {
	my ($class, $id) = @_;

	my $artist = Plugins::Qobuz::API::Sync->getArtist($someUserId, $id);
	return ($artist && ref $artist) ? $artist->{picture} : '';
} }

sub trackUriPrefix { 'qobuz://' }

# This code is not run in the scanner, but in LMS
sub needsUpdate { if (!main::SCANNER) {
	my ($class, $cb) = @_;

	require Async::Util;
	require Plugins::Qobuz::API;

	my @workers = map {
		my $account = $_;

		sub {
			my ($result, $acb) = @_;

			# don't run any further test in the queue if we already have a result
			return $acb->($result) if $result;

			my $api = Plugins::Qobuz::API->new({ userId => $account->[1]}) || return $acb->();

			$api->updateUserdata(sub {
				my $result = shift;

				my $needUpdate;

				if ($result && ref $result eq 'HASH' && $result->{last_update} && ref $result->{last_update} eq 'HASH') {
					my $timestamps = Storable::dclone($result->{last_update});
					delete $timestamps->{playlist} if $class->_ignorePlaylists;

					$needUpdate = $cache->get('last_update') < max(values %$timestamps);
				}

				$acb->($needUpdate);
			});
		}
	} @{ _enabledAccounts() };

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
} }

sub _ignorePlaylists {
	my $class = shift;
	return $class->can('ignorePlaylists') && $class->ignorePlaylists;
}

sub _prepareTrack {
	my ($album, $track, $albumArtists) = @_;

	my $url = Plugins::Qobuz::API::Common->getUrl(undef, $track) || return;
	my $ct  = Slim::Music::Info::typeFromPath($url);

	my $attributes = {
		url          => $url,
		TITLE        => Plugins::Qobuz::API::Common->addVersionToTitle($track),
		ALBUM        => $album->{title},
		ALBUM_EXTID  => 'qobuz:album:' . $album->{id},
		TRACKNUM     => $track->{track_number},
		GENRE        => $album->{genre},
		SECS         => $track->{duration},
		YEAR         => substr($album->{release_date_stream},0,4),
		COVER        => $album->{image},
		AUDIO        => 1,
		EXTID        => $url,
		TIMESTAMP    => $album->{favorited_at} || $album->{purchased_at},
		CONTENT_TYPE => $ct,
		SAMPLERATE   => $track->{maximum_sampling_rate} * 1000,
		SAMPLESIZE   => $track->{maximum_bit_depth},
		CHANNELS     => $track->{maximum_channel_count},
		LOSSLESS     => $ct eq 'flc',
		RELEASETYPE  => $album->{release_type} =~ /^[a-z]+$/ ? ucfirst($album->{release_type}) : $album->{release_type},
		REPLAYGAIN_ALBUM_GAIN => $album->{replay_gain},
		REPLAYGAIN_ALBUM_PEAK => $album->{replay_peak},
	};

	$album->{release_type} = 'EP' if lc($album->{release_type} || '') eq 'epmini';

	if ($album->{media_count} > 1) {
		$attributes->{DISC} = $track->{media_number};
		$attributes->{DISCC} = $album->{media_count};
	}

	if ( $track->{composer} && $track->{composer}->{name} && $track->{composer}->{name} !~ /^\s*various\s*composers\s*$/i ) {
		$attributes->{COMPOSER} = $track->{composer}->{name};
		$attributes->{COMPOSER_EXTID} = 'qobuz:artist:' . $track->{composer}->{id};
		if ( $track->{work} && $prefs->get('importWorks') ) {
			$attributes->{WORK} = $track->{work};
		}
	}

	if ($track->{audio_info}) {
		$attributes->{REPLAYGAIN_TRACK_GAIN} = $track->{audio_info}->{replaygain_track_gain};
		$attributes->{REPLAYGAIN_TRACK_PEAK} = $track->{audio_info}->{replaygain_track_peak};
	}

	my ($artists, $artistIds);

	foreach ( Plugins::Qobuz::API::Common->getMainArtists($album) ) {
		push @$artists, $_->{name};
		push @$artistIds, 'qobuz:artist:' . $_->{id};
	}
	if ( !$artists && $track->{performer} && $track->{performer}->{name} ) {
		push @$artists, $track->{performer}->{name};
		push @$artistIds, 'qobuz:artist:' . $track->{performer}->{id};
	}

	Plugins::Qobuz::API::Common->removeArtistsIfNotOnTrack($track, $artists, $artistIds);

	if ($track->{performer} && Plugins::Qobuz::API::Common->trackPerformerIsMainArtist($track) && !grep $_ eq $track->{performer}->{name}, @{$artists}) {
		push @$artists, $track->{performer}->{name};
		push @$artistIds, 'qobuz:artist:' . $track->{performer}->{id};
	}

	my $rolePerformer;
	if ($track->{performers}) {
		my %seen;
		my @performersAndRoles = split(' - ', $track->{performers});
		foreach my $performerAndRoles (@performersAndRoles) {
			my %roleSeen = undef;
			my @roles = split(/\s*,\s*/, $performerAndRoles);
			my $name = shift @roles;
			foreach my $role (@roles) {
				$role =~ s/\s*//gs;
				$role = uc($role);
				push @{$rolePerformer->{$role}}, $name if !$roleSeen{$role};
				$roleSeen{$role} = 1;
			}
		}
		$attributes->{BAND} = $rolePerformer->{ORCHESTRA} if $rolePerformer->{ORCHESTRA};
		$attributes->{CONDUCTOR} = $rolePerformer->{CONDUCTOR} if $rolePerformer->{CONDUCTOR};
	}

	$attributes->{ARTIST} = \@$artists;
	$attributes->{ARTIST_EXTID} = \@$artistIds;

	# create a map of artist id -> artist name tuples for the current item
	my %trackArtists;
	for (my $i = 0; $i < scalar @{$attributes->{ARTIST}}; $i++) {
		$trackArtists{$attributes->{ARTIST}->[$i]} = $attributes->{ARTIST_EXTID}->[$i];
	}

	# if this is the first track, all track artists are potential album artists
	if (!$albumArtists->{names}) {
		$albumArtists->{names} = [ keys %trackArtists ];
		$albumArtists->{ids} = [ values %trackArtists ];
	}
	# not the first track
	else {
		if ( !$albumArtists->{required} && join(',', sort(@{$albumArtists->{names}})) ne join(',', sort(@$artists)) ) {
			$albumArtists->{required} = 1;
		}
		# we are only interested in the artists we have seen before - anything else is not considered an album artist
		for (my $i = 0; $i < scalar @{$albumArtists->{names}}; $i++) {
			if (!$trackArtists{$albumArtists->{names}->[$i]}) {
				$albumArtists->{names}->[$i] = undef;
				$albumArtists->{ids}->[$i] = undef;
			}
		}

		# instead of fiddling with the index above I decided to wipe the value - now we have to remove empty values
		@{$albumArtists->{names}} = grep { $_ } @{$albumArtists->{names}};
		@{$albumArtists->{ids}} = grep { $_ } @{$albumArtists->{ids}};
	}

	$attributes->{ALBUMARTIST} = $albumArtists->{names};
	$attributes->{ALBUMARTIST_EXTID} = $albumArtists->{ids};

	return $attributes;
}

sub _checkAlbumArtists {
	my ($attributes, $albumArtists) = @_;

	if ( !$albumArtists->{required} || !scalar @{$albumArtists->{names}} ) {
		foreach (@$attributes) {
			delete $_->{ALBUMARTIST};
			delete $_->{ALBUMARTIST_EXTID};
		}
	}
	return;
}

1;
