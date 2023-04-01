package Plugins::Qobuz::Settings;

use strict;
use base qw(Slim::Web::Settings);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Digest::MD5 qw(md5_hex);


# Used for logging.
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
			'appendVersionToTitle', 'sortFavsAlphabetically', 'sortArtistAlbums', 'showYearWithAlbum', 'useClassicalEnhancements', 'classicalGenres');
}

sub handler {
	my ($class, $client, $params) = @_;

	if ($params->{'saveSettings'} && $params->{'username'}) {
		if ($params->{'username'}) {
			my $username = $params->{'username'};
			$prefs->set('username', "$username"); # add a leading space to make the message display nicely
		}

		if ($params->{'password'} && ($params->{'password'} ne "****")) {
			my $password_md5_hash = md5_hex($params->{'password'});
			$prefs->set('password_md5_hash', "$password_md5_hash"); # add a leading space to make the message display nicely
		}

		if ($params->{'preferredFormat'}) {
			my $preferredFormat = $params->{'preferredFormat'};
			$prefs->set('preferredFormat', "$preferredFormat"); # add a leading space to make the message display nicely
		}

		$params->{pref_filterSearchResults} ||= 0;
		$params->{pref_playSamples} ||= 0;
		$params->{pref_dontImportPurchases} ||= 0;
	}

	# This puts the value on the webpage.
	# If the page is just being displayed initially, then this puts the current value found in prefs on the page.
	$params->{'prefs'}->{'username'} = $prefs->get('username');
	$params->{'prefs'}->{'password_md5_hash'} = "****";
	$params->{'prefs'}->{'preferredFormat'} = $prefs->get('preferredFormat');

	# I have no idea what this does, but it seems important and it's not plugin-specific.
	return $class->SUPER::handler($client, $params);
}

1;

__END__
