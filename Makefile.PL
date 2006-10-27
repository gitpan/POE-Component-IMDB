use 5.006001;
use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME              => 'POE::Component::IMDB',
    VERSION_FROM      => 'lib/POE/Component/IMDB.pm', # finds $VERSION
    PREREQ_PM         => {
			POE => 0.38,
			'POE::Session' => 1.2123,
			'POE::Component::Client::HTTP' => 0.79,
			'URI::Escape' => 3.28,
			'HTTP::Request' => 1.40,
			'HTML::TreeBuilder' => 3.13,
			'Data::Dumper' => 2.121,
		}, 
    ($] >= 5.005 ?     ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM  => 'lib/POE/Component/IMDB.pm', # retrieve abstract from module
       AUTHOR         => 'buu') : ()),
);
