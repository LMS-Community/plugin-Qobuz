package Plugins::Qobuz::Settings;

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

sub prefs {
	return ($prefs, 'filterSearchResults', 'playSamples', 'showComposerWithArtist', 'labelHiResAlbums', 'dontImportPurchases',
			'appendVersionToTitle', 'sortFavsAlphabetically', 'sortArtistAlbums', 'showYearWithAlbum', 'useClassicalEnhancements',
			'classicalGenres', 'workPlaylistPosition', 'parentalWarning', 'showDiscs', 'preferredFormat');
}

sub handler {
 	my ($class, $client, $params, $callback, @args) = @_;

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
			next if $k !~ /pref_dontimport_(.*)/;

			my $id = $1;
			my $account = $accounts->{$id} || next;

			if ($params->{$k}) {
				$account->{dontimport} = 1;
			}
			else {
				delete $account->{dontimport};
			}
		}

		if ($params->{'username'} && $params->{'password'}) {
			my $username = $params->{'username'};
			my $password = md5_hex($params->{'password'});

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
	$params->{accounts} = Plugins::Qobuz::API::Common->getAccountList();
	$params->{canImporter} = Plugins::Qobuz::Plugin::CAN_IMPORTER;
}

1;

__END__
