use lib 'lib';
use POE;
use POE::Session;
use POE::Component::IMDB;
use Data::Dumper;

my $session = POE::Session->create(
	package_states => [
		main => [ qw/_start imdb_FetchedMovie/ ],
	],
);

sub _start
{
	my( $heap, $kernel ) = @_[HEAP,KERNEL];
	
	$heap->{imdb} = POE::Component::IMDB->new( qw/imdb_FetchedMovie/ );
	$heap->{imdb}->fetch_movie("full metal jacket");
}

sub imdb_FetchedMovie
{
	my( $heap, $movie_object ) = @_[HEAP,ARG0];
	
	print Dumper $movie_object;
}

$poe_kernel->run;

