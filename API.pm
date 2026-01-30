package Plugins::Qobuz::API;

#Sven 2026-01-29 enhancements version 30.6.7
# All changes are marked with "#Sven" in source code
# 2020-03-30 getArtist() new parameter $noalbums, if it is not undef, getArtist() returns no extra album information
# 2022-05-13 added function setFavorite()
# 2022-05-13 added function getFavoriteStatus()
# 2022-05-14 added function doPlaylistCommand()
# 2022-05-20 added MyWeekly playlist
# 2022-05-20 new parameter $type for getUserFavorites()
# 2022-05-23 getAlbum() new parameter 'extra' and one optimisation
# 2022-05-23 added function getSimilarPlaylists()
# 2023-10-07 Update of app_id handling
# 2023-10-09 add sort configuration for function getUserPlaylists()
# 2024-03-01 _pagingGet() optimisations, no limitations for albums, artists, tracks, playlists and search
# 2025-10-21 getAlbums() used for 'albums of the week' and 'release radar'
# 2025-10-16 added function _pagingGetMore()
# 2025-10-21 added function getData()
# 2025-10-23 added function getRadio()
# 2025-10-29 added function _post(), for future use
# 2025-10-30 added function getArtistPage()
# 2025-11-01 optimisation of _lookupArtistPicture()
# 2025-11-04 added functions getArtistPicture(), getArtistImageFromHash()
# 2025-12-28 getRadio() - fix to support ReplayGain
# 2026-01-17 'userid' den Track-Metadaten hinzugefügt.

# $log->error(Data::Dump::dump($albums));
use strict;
use base qw(Slim::Utils::Accessor);

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);

use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use URI::Escape qw(uri_escape_utf8);
use Digest::MD5 qw(md5_hex);
use Scalar::Util qw(blessed);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Qobuz::API::Common;

use constant URL_EXPIRY => 60 * 10;       # Streaming URLs are short lived
use constant BROWSER_UA => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2.1 Safari/605.1.15';

# bump the second parameter if you decide to change the schema of cached data
my $cache = Plugins::Qobuz::API::Common->getCache();
my $prefs = preferences('plugin.qobuz');
my $log = logger('plugin.qobuz'); 

my %apiClients;

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		userId
	) );
}

sub new {
	my ($class, $args) = @_;

	if (!$args->{client} && !$args->{userId}) {
		return;
	}
	
	my $client = $args->{client};

	my $userId = $args->{userId} || Plugins::Qobuz::API::Common->getUserId($client) || return;

	if (my $apiClient = $apiClients{$userId}) {
		return $apiClient;
	}

	my $self = $apiClients{$userId} = $class->SUPER::new();
	$self->client($client);
	$self->userId($userId);

	# update our profile ASAP
	$self->updateUserdata();

	return $self;
}

my ($aid, $as, $cid);

sub init {
	($aid, $as, $cid) = Plugins::Qobuz::API::Common->init(@_);
}

sub login {
	my ($class, $username, $password, $cb, $args) = @_;

	if ( !($username && $password) ) {
		$cb->() if $cb;
		return;
	}

	my $params = {
		username => $username,
		password => $password,
		device_manufacturer_id => preferences('server')->get('server_uuid'),
		_nocache => 1,
		_cid     => $args->{cid} ? 1 : 0,
	};

	$class->_get('user/login', sub {
		my $result = shift;

		main::INFOLOG && $log->is_info && !$log->is_info && $log->info(Data::Dump::dump($result));

		my ($token, $user_id);
		if ( ! ($result && ($token = $result->{user_auth_token}) && $result->{user} && ($user_id = $result->{user}->{id})) ) {
			$log->warn('Failed to get token');
			$cb->() if $cb;
			return;
		}

		my $accounts = $prefs->get('accounts') || {};

		if (!$args || !$args->{cid}) {
			$accounts->{$user_id}->{token} = $token;
			$accounts->{$user_id}->{userdata} = $result->{user};

			$class->login($username, $password, sub {
				$cb->(@_) if $cb;
			}, {
				cid => 1,
				token => $token,
			});
		}
		else {
			$accounts->{$user_id}->{webToken} = $token;
			$cb->($args->{token}) if $cb;
		}

		$prefs->set('accounts', $accounts);
	}, $params);
}

sub updateUserdata {
	my ($self, $cb) = @_;

	$self->_get('user/get', sub {
		my $result = shift;

		if ($result && ref $result eq 'HASH') {
			my $userdata = Plugins::Qobuz::API::Common->getUserdata($self->userId);

			foreach my $k (keys %$result) {
				$userdata->{$k} = $result->{$k} if defined $result->{$k};
			}

			$prefs->save();
		}

		$cb->($result) if $cb;
	},{
		user_id => $self->userId,
		_nocache => 1,
	})
}

sub search {
	my ($self, $cb, $search, $type, $args) = @_;

	$args ||= {};

	$search = lc($search);

	main::INFOLOG && $log->info('Search : ' . $search);

	my $key = uri_escape_utf8("search_${search}_${type}_") . ($args->{_dontPreCache} || 0);

	if ( my $cached = $cache->get($key) ) {
		$cb->($cached);
		return;
	}

	$args->{limit} ||= QOBUZ_USERDATA_LIMIT;
	$args->{_ttl}  ||= QOBUZ_EDITORIAL_EXPIRY;
	$args->{query} ||= $search;
	$args->{type}  ||= $type if $type =~ /(?:albums|artists|tracks|playlists)/;

	my $getCB = sub {
		my $results = shift;

		if ( !$args->{_dontPreCache} ) {
			$self->_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

			$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

			$results->{tracks}->{items} = _precacheTracks($results->{tracks}->{items}) if $results->{tracks}->{items};
		}

		$cache->set($key, $results, 300);

		$cb->($results) if $cb;
	};

	if ($type) { $self->_pagingGet('catalog/search', $getCB, $args, $type); }
	else { $self->_get('catalog/search', $getCB, $args); }
}

#Sven 2025-10-16, 2025-12-30
sub getRadio {
	my ($self, $cb, $args) = @_;
	
	my $type = ($args->{album_id}) ? 'album' : (($args->{artist_id}) ? 'artist' : 'track');
	
	$args->{limit}      = 50;
	$args->{_ttl}       = QOBUZ_EDITORIAL_EXPIRY;
	$args->{_use_token} = 1; # muss immer angegeben werden um user_auth_token zu ermitteln
	$args->{_cid}       = 1; # muss immer angegeben werden wenn das webToken benutzt werden soll, da es ohne Angabe immer _cid => 0 angenommen wird.

	$self->_get('radio/' . $type, sub {
		my $radio = shift;

		#Sven 2025-12-28
		# Die $radio->{tracks}->{items} enthalten keine ReplayGain-Informationen
		# Daher werden diese Informationen mit _post('track/getList') noch separat geholt.
		# Dabei werden zwei API-Aufrufe verschachtelt, beim zweiten Aufruf wird user_auth_token direkt aus dem ersten $self->get() übernommen.
		# Wenn man bei _get() oder _post() statt _use_token = 1 gleich den korrekten user_auth_token eingibt
		# muss er in allen folgenden API-Calls nicht nochmals ermittelt werden.
		
		my $trackIds = to_json({ tracks_id => [ map { $_->{id} } @{$radio->{tracks}->{items}} ] }); # Erstellen der ID-Trackliste

		$self->_post('track/getList', sub {
			my $result = shift;

			$radio->{tracks}->{items} = _precacheTracks($result->{tracks}->{items});
			
			$cb->($radio);
		}, { _cid => 1, _use_token => 1, user_auth_token => $args->{user_auth_token}, data => $trackIds });	# user_auth_token ist hier bereis aus dem letzten _get() oben bekannt
	#	}, { _cid => 1, _use_token => 1, data => $trackIds }); # hier wird user_auth_token erneut ermittelt
		
	}, $args);
}

#Sven 2020-03-30 new parameter $noalbums, if it is not undef, getArtist returns no extra album information.
sub getArtist {
	my ($self, $cb, $artistId, $noalbums) = @_;

	$self->_get('artist/get', sub {
		my $results = shift;

		if ( $results && (my $images = $results->{image}) ) {
			my $image = Plugins::Qobuz::API::Common->getImageFromImagesHash($images);
			$self->_precacheArtistPictures([ { id => $artistId, picture => $image } ]) if $image;
		}

		$results->{albums}->{items} = _precacheAlbum($results->{albums}->{items}) if $results->{albums};

		$cb->($results) if $cb;
	}, $noalbums ? { artist_id => $artistId } : { #Sven 2020-03-30 new parameter $noalbums
		artist_id => $artistId,
		extra     => 'albums',
		limit     => QOBUZ_DEFAULT_LIMIT,
	});
}

#Sven 2025-10-31
sub getArtistPage {
	my ($self, $cb, $artistId) = @_;

	$self->_get('artist/page', sub {
		my $results = shift;

		$results->{name} = $results->{name}->{display};

		if ( $results && $results->{images} ) {
			$results->{image} = $self->getArtistImageFromHash($artistId, $results->{images}->{portrait});
			delete $results->{images};
		}

		foreach ( @{$results->{similar_artists}->{items}}) {
			$_->{picture} = $self->getArtistImageFromHash($_->{id}, $_->{images}->{portrait});
			$_->{name} = $_->{name}->{display};
			delete $_->{images};
		}

		$results->{top_tracks} = _precacheTracks($results->{top_tracks});
		
		if ($results->{last_release}) {
			my $albums = _precacheAlbum([$results->{last_release}]);
            $results->{last_release} = @$albums[0];
		}

		foreach (@{$results->{releases}}) {		
			$_->{items} = _precacheAlbum($_->{items});
		}

		$results->{tracks_appears_on} = _precacheTracks($results->{tracks_appears_on});

		$cb->($results) if $cb;
	}, { 
		limit     => 50,
		artist_id => $artistId,
		_cid	  => 1,
	});
}

#Sven 2025-12-28 - the get command used for a lot of new server commands
# $args - contains a hash with the parameters for control
# cmd   - the command that is sent to the Qobuz server contains
# args  - Contains, if necessary, the parameters that must be sent with the command.
# type  - contains the name of the result hash, 'artists' or 'playlists'
sub getData {
	my ($self, $cb, $pars) = @_;

	my $cmd  = $pars->{cmd};
	my $job  = (split(/\//, $cmd))[1];
	my $args = $pars->{args};
	my $type = $pars->{type} || '';
	my $func;

	$args->{_ttl} = QOBUZ_EDITORIAL_EXPIRY;
	$args->{_use_token} = 1;
	
	#if ($job eq 'get') { $args->{limit} = QOBUZ_USERDATA_LIMIT; $type = 'albums'; }
	if ($job eq 'page') { $func = \&_get; $args->{_cid} = 1; }
	else { $args->{_cid} = 1; }

	unless ($func) { 
		if ($args->{_cid}) { $func = \&_pagingGetMore; }
		else { 
			$func = \&_pagingGet;
			$args->{limit} = QOBUZ_USERDATA_LIMIT;
		}
	}

	$func->($self, $cmd, sub {
		my $result = shift;

		if ($result->{artists}) {
			foreach (@{$result->{artists}->{items}}) {		
				$_->{image} = $self->getArtistImageFromHash($_->{id}, $_->{image});
			};
		}

		if ($result->{albums}) {
			$result->{albums}->{items} = _precacheAlbum($result->{albums}->{items});
		}

		if ($result->{top_tracks}) {
			$result->{top_tracks} = _precacheTracks($result->{top_tracks});
		}
		
		if ($result->{releases}) {
			foreach (@{$result->{releases}}) {		
				$_->{data}->{items} = _precacheAlbum($_->{data}->{items});
			};
		}

		if ($result->{top_artists}) {
			foreach ( @{$result->{top_artists}->{items}} ) {
				$_->{image} = $self->getArtistImageFromHash($_->{id}, $_->{image});
			};
		}
		
		$cb->($result) if $cb;
	}, $args, $type);
}

#Sven 2025-11-04
sub getArtistPicture {
	my ($self, $artistId) = @_;

	my $url = $cache->get('artistpicture_' . $artistId) || '';

	unless ($url) {
		$self->_precacheArtistPictures([{ id => $artistId }]);
		$url = 'html/images/artists.png';
	}
	
	return $url;
}

#Sven 2025-11-04
sub getArtistImageFromHash {
	my ($self, $artistId, $image) = @_;

	return 'html/images/artists.png' unless $image->{hash}; 

	my $picture = "https://static.qobuz.com/images/artists/covers/large/" . $image->{hash} . "." . $image->{format};

	$self->_precacheArtistPictures([ { id => $artistId, picture => $picture } ]);

	return $picture;
}

#Sven 2022-05-23
sub getSimilarArtists {
	my ($self, $cb, $artistId) = @_;

	$self->_pagingGet('artist/getSimilarArtists', sub {
		my $results = shift;

		$self->_precacheArtistPictures($results->{artists}->{items}) if $results && $results->{artists};

		$cb->($results);
	}, {
		artist_id => $artistId,
		limit     => QOBUZ_USERDATA_LIMIT,	# max. is 100
	}, 'artists');
}

sub getGenres {
	my ($self, $cb, $genreId) = @_;

	my $params = {};
	$params->{parent_id} = $genreId if $genreId;

	$self->_get('genre/list', $cb, $params);
}

#Sven 2022-05-23 neuer Parameter 'extra' und eine Optimierung
sub getAlbum {
	my ($self, $cb, $args) = @_;
	# $args enthält entweder direkt die album_id oder ein Array
	# mit den Hashwerten 'album_id' und optional 'extra'
	# album_id => $albumId,
	# extra    => 'albumsFromSameArtist', 'focus','focusAll',

	if (! ref $args) { $args = { album_id => $args }; };
	
	# $self->_pagingGet('album/get', sub { # Wozu Paging bei den Tracks eines einzigen Albums?????
	# Funktioniert mit meiner Version von Plugin:QobuzGetTracks() nicht
	$self->_get('album/get', sub {
		my $album = shift;
		
		if ($album) {
			#<Sven 2022-05-23
			if ($album->{albums_same_artist} && $album->{albums_same_artist}->{items}) {
				$album->{albums_same_artist}->{items} = _precacheAlbum($album->{albums_same_artist}->{items});
			}
			#>Sven
			($album) = @{_precacheAlbum([$album])};
		}

		$cb->($album);
	}, $args); #, 'tracks');
}

sub getFeaturedAlbums {
	my ($self, $cb, $type, $genreId) = @_;

	my $args = {
		type     => $type,
		limit    => QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_EDITORIAL_EXPIRY,
	};

	$args->{genre_ids} = $genreId if $genreId;
	
	$self->_pagingGet('album/getFeatured', sub {
		my $albums = shift;
		
		$albums->{albums}->{items} = _precacheAlbum($albums->{albums}->{items}) if $albums->{albums};
		
		$cb->($albums);
	}, $args, 'albums');
}

sub getUserPurchases {
	my ($self, $cb, $limit) = @_;

	$self->_get('purchase/getUserPurchases', sub {
		my $purchases = shift;

		$purchases->{albums}->{items} = _precacheAlbum($purchases->{albums}->{items}) if $purchases->{albums};
		$purchases->{tracks}->{items} = _precacheTracks($purchases->{tracks}->{items}) if $purchases->{tracks};

		$cb->($purchases);
	},{
		limit    => $limit || QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token => 1,
	});
}

sub getUserPurchasesIds {
	my ($self, $cb) = @_;

	$self->_get('purchase/getUserPurchasesIds', sub {
		$cb->(@_) if $cb;
	},{
		_user_cache => 1,
		_use_token => 1,
	})
}

sub checkPurchase {
	my ($self, $type, $id, $cb) = @_;

	$self->getUserPurchasesIds(sub {
		my ($purchases) = @_;

		$type = $type . 's';
		if ( $purchases && ref $purchases && $purchases->{$type} && ref $purchases->{$type} && (my $items = $purchases->{$type}->{items}) ) {
			if ( $items && ref $items && scalar @$items ) {
				$cb->(
					(grep { $_->{id} =~ /^\Q$id\E$/i } @$items)
					? 1
					: 0
				);
				return;
			}
		}
		$cb->();
	});
}

#Sven 2022-05-20 new parameter $type
sub getUserFavorites {
	my ($self, $cb, $type, $force) = @_;

	$self->_pagingGet('favorite/getUserFavorites', sub {
		my ($favorites) = @_;

		$favorites->{albums}->{items} = _precacheAlbum($favorites->{albums}->{items})  if $favorites->{albums};
		$favorites->{tracks}->{items} = _precacheTracks($favorites->{tracks}->{items}) if $favorites->{tracks};

		$cb->($favorites);
	}, {
		limit => QOBUZ_USERDATA_LIMIT,
		type  => $type, #Sven - Parameter für Qobuz API 'favorite/getUserFavorites'
		_ttl       => QOBUZ_USER_DATA_EXPIRY,
		_use_token => 1,
		_wipecache => $force,
	}, $type);
}

#Sven 2022-05-13 add
sub setFavorite {
	my ($self, $cb, $args) = @_;

	my $command = 'favorite/' . ($args->{add} ? 'create' : 'delete');
	my $type = $args->{album_ids} ? 'albums' : ($args->{track_ids} ? 'tracks' : 'artists');

	delete $args->{add};
	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;

	$self->_get($command, sub {
		my $result = shift;
		$self->getUserFavorites(sub{$cb->($result)}, $type, 'refresh');
	}, $args);
}

#Sven 2022-05-13 add
sub getFavoriteStatus {
	my ($self, $cb, $args) = @_; # $args = { item_id => ...., type = ...}   Accepted values for type are 'album', 'track', 'artist', 'article'

	$args->{_use_token} = 1;
	$args->{_nocache}   = 1;

	$self->_get('favorite/status', sub { $args->{status} = (shift->{status} eq JSON::XS::true()); $cb->($args); }, $args);
}

#Sven 2023-10-09 einstellbare Sortierung
sub getUserPlaylists {
	my ($self, $cb, $args) = @_;
	
	$args = $args || {};

	my $myArgs = {
		user_id  => $args->{user_id} || $self->userId, #Sven
		limit    => $args->{limit} || QOBUZ_USERDATA_LIMIT,
		_ttl     => QOBUZ_USER_DATA_EXPIRY,
		_user_cache => 1,
		_use_token  => 1,
	};
	
	$myArgs->{_wipecache} = 1 if $args->{force};
	
	my $sort = $cb;
	
	if ($prefs->get('sortUserPlaylists') || 0 == 1) {
		$sort = sub {
			my $playlists = shift;

			$playlists->{playlists}->{items} = [ sort {
				lc($a->{name}) cmp lc($b->{name})
			} @{$playlists->{playlists}->{items} || []} ] if $playlists && ref $playlists && $playlists->{playlists} && ref $playlists->{playlists};
		
			$cb->($playlists);
		};
	};

	$self->_pagingGet('playlist/getUserPlaylists', $sort , $myArgs, 'playlists');

}

#Sven 2022-05-14 add
sub doPlaylistCommand {
	my ($self, $cb, $args) = @_;
	
	$self->_get('playlist/' . $args->{command}, sub {
		my $result = shift;
		$self->getUserPlaylists(sub{$cb->($result)}, { force => 'refresh'});
	}, {
		playlist_id => $args->{playlist_id},
		_use_token => 1,
		_nocache => 1
	});
}

#Sven 2022-05-23 add
sub getSimilarPlaylists {
	my ($self, $cb, $args) = @_;
	
	$self->_get('playlist/get', $cb, {
		playlist_id => $args->{playlist_id},
		extra	    => 'getSimilarPlaylists',
		limit	    => QOBUZ_USERDATA_LIMIT,
		_ttl	    => QOBUZ_USER_DATA_EXPIRY,
		_use_token  => 1,
	});
}

sub getPublicPlaylists {
	my ($self, $cb, $type, $genreId, $tags) = @_;

	my $args = {
		type  => $type =~ /(?:last-created|editor-picks)/ ? $type : 'editor-picks',
		limit => QOBUZ_USERDATA_LIMIT,
		_ttl  => QOBUZ_EDITORIAL_EXPIRY,
		_use_token => 1,
	};

	$args->{genre_ids} = $genreId if $genreId;
	$args->{tags} = $tags if $tags;

	$self->_pagingGet('playlist/getFeatured', $cb, $args, 'playlists'); 
}

sub getPlaylistTracks {
	my ($self, $cb, $playlistId) = @_;

	$self->_pagingGet('playlist/get', sub {
		my $tracks = shift;

		$tracks->{tracks}->{items} = _precacheTracks($tracks->{tracks}->{items});

		$cb->($tracks);
	},{
		playlist_id => $playlistId,
		extra       => 'tracks',
		limit       => QOBUZ_USERDATA_LIMIT,
		_ttl        => QOBUZ_USER_DATA_EXPIRY,
		_use_token  => 1,
	}, 'tracks');
}

sub getTags {
	my ($self, $cb) = @_;

	$self->_get('playlist/getTags', sub {
		my $result = shift;

		my $tags = [];

		if ($result && ref $result && $result->{tags} && ref $result->{tags}) {
			$tags = [ grep {
				$_->{id} && $_->{name};
			} map {
				my $name = eval { from_json($_->{name_json}) };
				{
					featured_tag_id => $_->{featured_tag_id},
					id => $_->{slug},
					name => $name
				};
			} @{$result->{tags}} ];
		}

		$cb->($tags);
	},{
		_use_token => 1
	});
}

#Sven 2026-01-17 die Qobuz UID 'userid' in den Metadaten wird für History benötigt, damit der Wiedergabeverlauf pro Qobuz-Benutzer möglich ist.
# Die Funktion wird von der Funktion getMetadataFor() in Plugins::Qobuz::ProtocolHandler aufgerufen.
sub getTrackInfo {
	my ($self, $cb, $trackId) = @_;

	return $cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	my $meta = $cache->get('trackInfo_' . $trackId);

	if ($meta) {
		$meta->{userid} = $self->userId; #Sven 2026-01-17
		$cb->($meta);
		return $meta;
	}

	$self->_get('track/get', sub {
		my $meta = shift || { id => $trackId };

		$meta = precacheTrack($meta);

		$meta->{userid} = $self->userId; #Sven 2026-01-17

		$cb->($meta);
	},{
		track_id => $trackId
	});
}

#Sven 2026-01-27
sub getHistory {
	my ($self, $client, $count) = @_;

	my $request = Slim::Control::Request::executeRequest($client, ['history', 'query', ['qobuz', $self->userId, $count, {}]]);
	my $items;
	eval { $items = $request->getResult('_aValue'); };

	# $log->error(Data::Dump::dump($items));
}

sub getFileUrl {
	my ($self, $cb, $trackId, $format, $client) = @_;

	my $maxSupportedSamplerate = min(map {
		$_->maxSupportedSamplerate
	} grep {
		$_->maxSupportedSamplerate
	} $client->syncGroupActiveMembers);

	$self->getFileInfo($cb, $trackId, $format, 'url', $maxSupportedSamplerate);
}

sub getFileInfo {
	my ($self, $cb, $trackId, $format, $urlOnly, $maxSupportedSamplerate) = @_;

	$cb->() unless $trackId;

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	my $preferredFormat;

	if ($format =~ /fl.c/i) {
		$preferredFormat = $prefs->get('preferredFormat');
		if ($preferredFormat < QOBUZ_STREAMING_FLAC_HIRES || ($maxSupportedSamplerate && $maxSupportedSamplerate < 48_000)) {
			$preferredFormat = QOBUZ_STREAMING_FLAC;
		}
		elsif ($preferredFormat > QOBUZ_STREAMING_FLAC_HIRES) {
			if ($maxSupportedSamplerate && $maxSupportedSamplerate <= 96_000) {
				$preferredFormat = QOBUZ_STREAMING_FLAC_HIRES;
			}
		}
	}
	elsif ($format =~ /mp3/i) {
		$preferredFormat = QOBUZ_STREAMING_MP3 ;
	}

	$preferredFormat ||= $prefs->get('preferredFormat') || QOBUZ_STREAMING_MP3;

	if ( my $cached = $self->getCachedFileInfo($trackId, $urlOnly, $preferredFormat) ) {
		$cb->($cached);
		return $cached
	}

	$self->_get('track/getFileUrl', sub {
		my $track = shift;

		if ($track) {
			my $url = delete $track->{url};

			# cache urls for a short time only
			$cache->set("trackUrl_${trackId}_${preferredFormat}", $url, URL_EXPIRY);
			$cache->set("trackId_$url", $trackId, QOBUZ_DEFAULT_EXPIRY);
			$cache->set("fileInfo_${trackId}_${preferredFormat}", $track, QOBUZ_DEFAULT_EXPIRY);
			$track = $url if $urlOnly;
		}

		$cb->($track);
	},{
		track_id   => $trackId,
		format_id  => $preferredFormat,
		_ttl       => URL_EXPIRY,
		_sign      => 1,
		_use_token => 1,
	});
}

# this call is synchronous, as it's only working on cached data
sub getCachedFileInfo {
	my ($class, $trackId, $urlOnly, $preferredFormat) = @_;

	$preferredFormat ||= $prefs->get('preferredFormat');

	if ($trackId =~ /^http/i) {
		$trackId = $cache->get("trackId_$trackId");
	}

	return $cache->get($urlOnly ? "trackUrl_${trackId}_$preferredFormat" : "fileInfo_${trackId}_$preferredFormat");
}

my @artistsToLookUp;
my $artistLookup;
sub _precacheArtistPictures {
	my ($self, $artists) = @_;

	return unless $artists && ref $artists eq 'ARRAY';

	foreach my $artist (@$artists) {
		my $key = 'artistpicture_' . $artist->{id};
		if ($artist->{picture}) {
			$cache->set($key, $artist->{picture}, -1);
		}
		elsif (!$cache->get($key)) {
			push @artistsToLookUp, $artist->{id};
		}
	}

	$self->_lookupArtistPicture() if @artistsToLookUp && !$artistLookup;
}

sub _lookupArtistPicture {
	my ($self) = @_;

	if ( !scalar @artistsToLookUp ) {
		$artistLookup = 0;
	}
	else {
		$artistLookup = 1;
		$self->getArtist(sub { $self->_lookupArtistPicture() }, shift @artistsToLookUp, 1); #Sven 2025-11-01 - hier müssen keine Alben geholt werden, siehe getArtist()
	}
}

# Sven 2025-10-25 - Anpassung des Caching an die neue API Methoden ab 2025. Siehe ab Zeile 955
# Offenbar soll ein Album ('album/get?album_id=xxxxxxxx') welche nicht abspielbar ist nicht gecached werden.
# Dies wird geprüft indem zuerst geprüft wird, ob es den Parameter 'album_id' gibt.
# Alle Kommandos die 'album_id' nicht enthalten werden immer gecached.
# Wenn 'album_id' vorhanden ist wird geprüft, ob das Album 'release_date_stream' enthält und ob dessen Wert kleiner als der des Tagesdatums ist.
# Es wird also geprüft ob das Album gestream werden kann, in dem Fall wird es gecached.
# Das Problem hieran ist, dass das mit der alten API so funktionierte weil es nur eine Methode 'album/get' die einen Parameter 'album_id' hatte.
# In den neueren Versionen der API gibt es mehrer Methoden die ebenfalls den Parameter 'album_id' haben, die aber gänzlich andere Datenformate zurückliefern.
# Daher muss die alte Bedingung angepasst werden, damit die neuen Methoden mit Parameter 'album_id' auch gecached werden können.
# Das Cachen ist insofern wichtig, da bei einigen Listen ohne das Cachen merkwürdige Effekte auftreten.
# Zum Beispiel liefert 'Vorschläge' eine Liste von Alben ausgehend von dem gerade angezeigten Album dessen ID dann in 'album_id' steht.
# Nachdem diese Albenliste angezeigt wird und man ein Album anklickt passiert es häufig, dass ein ganz anderes Album aus der Liste angezeigt wird.
# Nach dem Cachen ist der Effekt verschwunden, vermutlich garantiert der Qobuz Server nicht immer die gleiche Reihenfolge der Listenelemente.
sub _get {
	my ( $self, $url, $cb, $params ) = @_;

	# need to get a token first?
	my $token = '';

	if ($url ne 'user/login' && blessed $self) {
		$token = ($params->{_cid} || 0)
			? Plugins::Qobuz::API::Common->getWebToken($self->userId)
			: Plugins::Qobuz::API::Common->getToken($self->userId);
		if ( !$token ) {
			$log->error('No or invalid user session');
			return $cb->();
		}
	}

	$params->{user_auth_token} = $token if delete $params->{_use_token};

	$params ||= {};

	my @query;
	while (my ($k, $v) = each %$params) {
		next if $k =~ /^_/;		# ignore keys starting with an underscore
		push @query, $k . '=' . uri_escape_utf8($v);
	}

	my $appId = (delete $params->{_cid} && $cid) || $aid;
	push @query, "app_id=$appId";

	# signed requests - see
	# https://github.com/Qobuz/api-documentation#signed-requests-authentification-
	if ($params->{_sign}) {
		my $signature = $url;
		$signature =~ s/\///;

		$signature .= join('', sort map {
			my $v = $_;
			$v =~ s/=//;
			$v;
		} grep {
			$_ !~ /(?:app_id|user_auth_token)/
		} @query);

		my $ts = time;
		$signature = md5_hex($signature . $ts . $as);

		push @query, "request_ts=$ts", "request_sig=$signature";

		$params->{_nocache} = 1;
	}

	$url = QOBUZ_BASE_URL . $url . '?' . join('&', sort @query);

	if (main::INFOLOG && $log->is_info) {
		my $data = $url;
		$data =~ s/(?:$aid|$token|$cid)//g;
		$log->info($data);
	}

	my $cacheKey = $url . ($params->{_user_cache} ? $self->userId : '');
	
	if ($params->{_wipecache}) {
		$cache->remove($cacheKey);
	}

	if (!$params->{_nocache} && (my $cached = $cache->get($cacheKey))) {
		if ( main::DEBUGLOG && $log->is_debug ) {
			$log->debug("found cached response: " . Data::Dump::dump($cached));
		}
		elsif ( main::INFOLOG && $log->is_info && $url =~ /album\/get\?/ ) {
			$log->info("found cached response: " . Data::Dump::dump($cached));
		}
		$cb->($cached);
		return;
	}

	my %headers = (
		'X-User-Auth-Token' => $token,
		'X-App-Id' => $appId,
	);

	$headers{'User-Agent'} = ($prefs->get('useragent') || BROWSER_UA) if $appId == $cid;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			$@ && $log->error($@);
			if ( main::DEBUGLOG && $log->is_debug && $url !~ /getFileUrl/i ) {
				$log->debug(Data::Dump::dump($result));
			}
			elsif ( main::INFOLOG && $log->is_info && $url =~ /album\/get\?/ ) {
				$log->info(Data::Dump::dump($result));
			}

			if ($result && !$params->{_nocache}) { #Sven 2025-10-25
				if (! ($params->{album_id}) ||                                                            # Wenn 'album_id' nicht vorhanden ist oder 
					! (exists $result->{release_date_stream}) ||                                          # wenn 'release_date_stream' nicht existiert oder
					$result->{release_date_stream} lt Slim::Utils::DateTime::shortDateF(time, "%Y-%m-%d") # wenn 'release_date_stream' kleiner als das Tagesdatum ist wird gecached.
				) { 
					$cache->set($cacheKey, $result, $params->{_ttl} || QOBUZ_DEFAULT_EXPIRY);
				}
			}

			$cb->($result);
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($http));

			$cb->();
		},
		{
			timeout => 15,
		},
	)->get($url, %headers);
}

# Da der Qobuz Server mit jedem angeforderten Request die Gesamtanzahl der Datensätze in dem Wert 'total' übermittelt,
# kann man die Anzahl der Aufrufe vorher berechnen und diese Befehle asynchron hintereinander absenden und muss nicht warten bis der Server die Anwort schickt.
# Da für diesen Fall nicht garantiert werden kann, dass die Antworten des Servers in der gleichen Reihenfolge zurück kommen wie die Anfragen gesendet wurden,
# benutzt die Funktion _pagingGet() dieses etwas kompliziert anmutende Verfahren mit chunks und der Zwischenspeicherung aller Teile in 'results'. 
# Erst wenn die letzte Anforderung vom Server beantwortet wurde wird dann der Ergebnisstring zusammengebaut.
# Für den Lyrion Server muss am Ende eine komplette Liste bestehend aus allen angeforderten Seiten übergeben werden.
# Ein echtes Paging wo das Holen der nächsten Seite von der Benutzeraktionen (scrollen oder sich seitenweise weiter bewegen) abhängt
# scheint der Lyrion Medis Server nicht zu unterstützen.
# Es gibt zwei Parameter:
# 'offset' gibt die Position an ab der gelesen wird.
# 'limit' gibt die maximale Anzahl an Datensätzen an die eingelsen werden sollen. Fehlt der Parameter wird ein Wert von 50 angenommen.
sub _pagingGet {
	my ( $self, $url, $cb, $params, $type ) = @_;

	return {} unless $type;

	my $limitTotal = $params->{limit}; # Die Anzahl der Datensätze die maximal eingelesen werden sollen.
	my $limitPage  = $params->{limit} = min($params->{limit}, QOBUZ_LIMIT); # Die Anzahl der Datensätze pro Anforderung

	$self->_get($url, sub {
		my ($result) = @_;

		my $count  = $result->{$type}->{limit} || $limitPage; # limit enthält immer nur den limit-Wert der bei der Anfrage mitgegeben wurde.
		my $total  = $result->{$type}->{total} || $count;     # total enthält die Gesamtanzahl der Datensätze der Liste
		$limitPage = $params->{limit} = $count if ( $count < $limitPage );

		main::DEBUGLOG && $log->is_debug && $log->debug("Need another page? " . Data::Dump::dump({
			total => $total,
			pageSize  => $limitPage,
			requested => $limitTotal
		}));

		if ($total > $limitPage && $limitTotal > $limitPage) {
			my $chunks = {};

			for (my $offset = $limitPage; $offset <= min($total, $limitTotal); $offset += $limitPage) {
				my $params2 = Storable::dclone($params);
				$params2->{offset} = $offset;
				$chunks->{$offset} = $params2;
			}

			my $extractorFn = sub {
				my ($results) = @_;

				my $collector;
				map {
					if ($collector) {
						push @{$collector->{$type}->{items}}, @{$results->{$_}->{$type}->{items}};
					}
					else {
						$collector = $results->{$_};
					}
				} sort {
					$a <=> $b
				} keys %$results;

				return $collector;
			};

			my $results = {
				0 => $result
			};
			
			while (my ($id, $params) = each %$chunks) {
				$self->_get($url, sub {
					$results->{$id} = shift;
					delete $chunks->{$id};
					if (!scalar keys %$chunks) {
						$cb->($extractorFn->($results));
					}
				}, $params);
			}
		}
		else {
			$cb->($result);
		}
	}, $params);
}

#Sven 2025-10-16 Paiging für Listen die mit 'has_more' arbeiten. Die neueren API Kommandos erhalten dieses Format zurück. 
# Da die API-Aufrufe verschachtelt sind ist die Reihenfolge vorgegeben, deshalb ist der Aufwand mit extractorFn() hier nicht notwendig.
# Nur wenn man mehrere asynchrone API-Aufrufe hintereinander ausführt, könnten die Ergebnisse möglicherweise nicht in der Reihenfolge eintreffen
# in der die zugehörigen API-Aufrufe erfolgten. Da hier jedoch am Anfang nicht bekannt ist wie lang die Liste wird, muss man Seite für Seite solange holen,
# bis der Server 'has_more' auf FALSE setzt. Mehrere Aufrufe hintereinander abzusetzen, wie das bei _paginGet() gemacht wird, ist also hier nicht möglich.
# Für den Lyrion Server muss am Ende ohnehin eine komplette Liste bestehend aus allen angeforderten Seiten übergeben werden.
# Ein echtes Paging wo das Holen der nächsten Seite von der Benutzeraktionen (scrollen oder sich seitenweise weiter bewegen) abhängt
# scheint vom Lyrion Media Server nicht unterstützt zu werden.
# Es gibt in $params zwei Parameter zur Steuerung:
# 'offset' gibt die Position an ab der gelesen wird.
# 'limit' gibt die maximale Anzahl an Datensätzen an die eingelsen werden sollen. Der maximal Wert ist 50. Alle höheren Werte werden alle durch 50 ersetzt.
# 'limit' kann auch weggelassen werden, dann wird auch automatische ein Wert von 50 angenommen.
# Falls das GET Kommando eine Liste ohne den Wert 'has_more' liefert wird nur ein _get() ausgeführt.
# Der Parameter $type kann 'albums', 'artists', 'tracks' und 'playlists' sein.
sub _pagingGetMore {
	my ( $self, $url, $cb, $params, $type ) = @_;
	
	my $limitTotal = $params->{limit} || QOBUZ_USERDATA_LIMIT;
	$params->{limit}  = ($params->{limit} && $params->{limit} < 50) ? $params->{limit} : 50; 
	$params->{offset} = 0 unless exists $params->{offset};
	
	my $cid = $params->{_cid};
	my $collector = [];
	my $offset = $params->{offset};
	my $getCBFn;
	
	$getCBFn = sub {
		$params->{offset} = $offset;
		$params->{_cid} = $cid if ($cid);
		
		$self->_get($url, sub {
			my $result = shift;

			if ($result) {
				$result = $result->{$type} if ($type &&  ! exists $result->{has_more});
			
				push @$collector, @{$result->{items}} if $result->{items};
				
				main::DEBUGLOG && $log->is_debug && $log->debug("Need another page? " . Data::Dump::dump({
					has_more => ($result->{has_more}) ? 'TRUE' : 'FALSE',
					offset => $offset
				}));
				
				if ($result->{has_more}) {
					$offset += scalar @{$result->{items}};
					if ($offset < $limitTotal) { 
						$getCBFn->();  #nächste Seite holen
						return;
					}
				}	
			}
			if ($type) { $cb->({ $type => { items => $collector } }); }
			else { $cb->({ items => $collector }); }
		}, $params); 	
	};	
			
	$getCBFn->();
}

#Sven 2025-10-29 - Da das neue Qobuz API mehrere POST Befehle enthält wurde _post() von Reporting.pm nach API.pm verschoben und vereinheitlicht.
sub _post {
	my ( $self, $url, $cb, $params ) = @_;

	$params ||= {};

	# need to get a token first?
	my $token = '';

	if (delete $params->{_use_token}) {      # wenn _use_token gleich 1 (oder > 0) ist, wird ein Token mit gesendet
		$token = $params->{user_auth_token}; # wenn user_auth_token bereits ein Token enthält wird es verwendet, sonst wird ein neues geladen 
		if (! $token) {
			if (blessed $self) { 
				$token = ($params->{_cid} || 0)
					? Plugins::Qobuz::API::Common->getWebToken($self->userId)
					: Plugins::Qobuz::API::Common->getToken($self->userId);
				$params->{user_auth_token} = $token;	
			}		
			if ( ! $token ) {
				$log->error('No or invalid user session');
				$cb->() if $cb;
				return;
			}
		}
	}

	my $appId = (delete $params->{_cid} ? $cid : $aid);

	$url = QOBUZ_BASE_URL . $url;

	$url .= '?app_id=' . $appId if $appId;
	$url .= '&user_auth_token=' . $token if $token;

	main::INFOLOG && $log->is_info && $log->info("$url " . $params->{data});

	#$log->error("$url " . $params->{data});

	my %headers = (
		'Content-Type' => 'application/json', # 'application/x-www-form-urlencoded'
		'X-App-Id' => $appId
	); 

	$headers{'Content-Type'} = $params->{_ContentType} if $params->{_ContentType};
	$headers{'X-User-Auth-Token'} = $token if $token;

	$headers{'User-Agent'} = ($prefs->get('useragent') || BROWSER_UA) if $appId == $cid;

	#$log->error("header: " . Data::Dump::dump(\%headers));

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			my $result = eval { from_json($response->content) };

			#$log->error(Data::Dump::dump($result));

			$@ && $log->error($@);
			main::DEBUGLOG && $log->is_debug && $log->debug("got $url: " . Data::Dump::dump($result));

			$cb->($result) if $cb;
		},
		sub {
			my ($http, $error) = @_;

			$log->warn("Error: $error ($url)");
			$cb->() if $cb;
		},
		{
			timeout => 15,
		},
	)->post($url, %headers, $params->{data});
}

sub aid { $aid }

1;