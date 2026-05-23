package Plugins::Qobuz::HomeExtras;

use strict;

use Slim::Utils::Log;
use Plugins::Qobuz::Plugin;

my $log = logger('plugin.qobuz');

Plugins::Qobuz::HomeExtraQobuz->initPlugin();
Plugins::Qobuz::HomeExtraBestsellers->initPlugin();
Plugins::Qobuz::HomeExtraPress->initPlugin();
Plugins::Qobuz::HomeExtraPicks->initPlugin();
Plugins::Qobuz::HomeExtraNewReleases->initPlugin();
# Plugins::Qobuz::HomeExtraWeeklyQ->initPlugin();

main::INFOLOG && $log->is_info && $log->info("Registered Home Extras for Qobuz");

1;

package Plugins::Qobuz::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, @_) },
		tag  => "QobuzExtras${tag}",
		extra => {
			title => $args{title},
			icon  => $args{icon} || Plugins::Qobuz::Plugin->_pluginDataFor('icon'),
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($tag, $client, $cb, $args) = @_;

	$args->{params}->{menu} = "home_heroes_${tag}";

	Plugins::Qobuz::Plugin::handleFeed($client, $cb, $args);
}

sub handleExtra {
	my ($class, $client, $cb, $count) = @_;

	$class->SUPER::handleExtra($client, sub {
		my $results = shift;

		my $icon = Plugins::Qobuz::Plugin->_pluginDataFor('icon');
		foreach (@{$results->{item_loop} || []}) {
			$_->{icon} ||= $icon;
		}

		$cb->($results);
	}, $count);
}

1;



package Plugins::Qobuz::HomeExtraQobuz;

use base qw(Plugins::Qobuz::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_QOBUZ',
		tag => 'qobuz'
	);
}

1;

package Plugins::Qobuz::HomeExtraBestsellers;

use base qw(Plugins::Qobuz::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_QOBUZ_BESTSELLERS',
		tag => 'best-sellers'
	);
}

1;

package Plugins::Qobuz::HomeExtraPress;

use base qw(Plugins::Qobuz::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_QOBUZ_PRESS',
		tag => 'press-awards'
	);
}

1;

package Plugins::Qobuz::HomeExtraPicks;

use base qw(Plugins::Qobuz::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_QOBUZ_EDITOR_PICKS',
		tag => 'editor-picks',
	);
}

1;

package Plugins::Qobuz::HomeExtraNewReleases;

use base qw(Plugins::Qobuz::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_QOBUZ_NEW_RELEASES',
		tag => 'new-releases-full',
	);
}

1;

# package Plugins::Qobuz::HomeExtraWeeklyQ;

# use base qw(Plugins::Qobuz::HomeExtraBase);

# sub initPlugin {
# 	my ($class, %args) = @_;

# 	$class->SUPER::initPlugin(
# 		title => 'PLUGIN_QOBUZ_MYWEEKLYQ',
# 		tag => 'weeklyq',
# 	);
# }

# 1;
