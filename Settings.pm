package Plugins::Qobuz::Settings;
#Sven 2025-12-28 enhancements Version 30.6.7
# All changes are marked with "#Sven" in source code
# 2025-12-23 enhancements for managing users, if Material sends "user_id:xxx"

use strict;
use Digest::MD5 qw(md5_hex);

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log   = logger('plugin.qobuz');
my $prefs = preferences('plugin.qobuz');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_QOBUZ');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Qobuz/settings/basic.html');
}

#Sven 2024-01-11
sub prefs {
	return ($prefs, 'filterSearchResults', 'playSamples', 'showComposerWithArtist', 'labelHiResAlbums', 'dontImportPurchases',
			'appendVersionToTitle', 'sortFavsAlphabetically', 'sortArtistAlbums', 'showYearWithAlbum', 'useClassicalEnhancements',
			'classicalGenres', 'workPlaylistPosition', 'parentalWarning', 'showDiscs', 'preferredFormat', 'groupReleases', 'importWorks',
			'sortPlaylists', 'showUserPurchases', 'sortArtistsAlpha', 'albumViewType');
}

sub handler {
 	my ($class, $client, $params, $callback, @args) = @_;

	# keep track of the user agent for request using the web token
	$prefs->set('useragent', $params->{userAgent}) if $params->{userAgent};

	my ($deleteId) = map {
		/^delete_(.*)/
	} grep {
		/^delete_.*/
	} keys %$params;

	my $accounts = $prefs->get('accounts');

	if ( $deleteId ) {
		delete $accounts->{$deleteId};
		$prefs->set('accounts', $accounts);
	}
	elsif ( $params->{add_account} || $params->{saveSettings} ) {
		$params->{'pref_filterSearchResults'} ||= 0;
		$params->{'pref_playSamples'}         ||= 0;
		$params->{'pref_dontImportPurchases'} ||= 0;

		foreach my $k (keys %$params) {
			next if $k !~ /pref_dontimport_(.*)/ && $k !~ /pref_lmsuser_(.*)/; #Sven 2025-12-23

			my $id = $1;
			my $account = $accounts->{$id} || next;

			if ( $k =~ /pref_dontimport_(.*)/ ) {
				if ($params->{$k}) {
					$account->{dontimport} = 1;
				}
				else {
					delete $account->{dontimport};
				}
			}
			else { #Sven 2025-12-23
				if ($params->{$k}) {
					$account->{lmsuser} = $params->{$k};
				}
				else {
					delete $account->{lmsuser};
				}
			}

		}

		if ($params->{'username'} && $params->{'password'} ) {
			my $username = $params->{'username'};
			my $password = md5_hex(Encode::encode("UTF-8", $params->{'password'}));

			Plugins::Qobuz::API->login($username, $password, sub {
				my $token = shift;

				if (!$token) {
					$params->{'warning'} = Slim::Utils::Strings::string('PLUGIN_QOBUZ_AUTH_FAILED');
				}

				my $body = $class->SUPER::handler($client, $params);
				$callback->( $client, $params, $body, @args );
			});

			return;
		}
	}

	$class->SUPER::handler($client, $params);
}

sub beforeRender {
	my ($class, $params, $client) = @_;
	$params->{accounts}    = Plugins::Qobuz::API::Common->getAccountList();
	$params->{canImporter} = Plugins::Qobuz::Plugin::CAN_IMPORTER;

	#Sven 2025-12-23
	foreach ( @{$params->{accounts}} ) {
		$_->[3] = $_->[0] unless ($_->[3]); 
	}
}

1;

__END__
