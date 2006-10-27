package POE::Component::IMDB;

use POE;
use POE::Session;
use POE::Component::Client::HTTP;
use URI::Escape qw/uri_escape/;
use HTTP::Request;
use HTML::TreeBuilder;
use Data::Dumper;
use strict;

our $VERSION = 0.50;

my $poco_client_http_alias = "poco-imdb-client-http";
my $base_uri = "http://www.imdb.com";
my $search_uri = "/find?s=all&q=%s";

sub new
{
	my( $class, @methods ) = @_;
	my $self = bless {}, $class;

	$self->{session} = POE::Session->create(
		object_states => [
			$self => [qw/_start proxy_post initial_request parse_intro_page 
				parse_fullcredits parse_quotes parse_trivia parse_goofs
			/] ,
		],
	);

	$self->{parent_session} = $poe_kernel->get_active_session();

	return $self;
}

sub normal_id
{
	my( $self, $string ) = @_;
	$string =~ s/\s+//g;
	$string =~ tr/([])'".,;:+=_-//d;

	return $string;
}

sub _start
{
	my( $self ) = @_[OBJECT];

  unless( $self->{http} = $poe_kernel->alias_resolve( $poco_client_http_alias ) )
  {
		POE::Component::Client::HTTP->spawn(
			Alias => $poco_client_http_alias
		);
		$self->{http}=$poco_client_http_alias;
  }
}

sub proxy_post
{
	my( $self, $kernel, @args ) = @_[OBJECT,KERNEL,ARG0..$#_];
	$kernel->post(@args);
}

sub fetch_movie
{
#TODO Caching and normalizing
	my( $self, $query ) = @_;
	my $search = sprintf( $base_uri . $search_uri, uri_escape( $query ) );

	my $nid = $self->normal_id( $query );
	$self->{search}{$nid}{query} = $query;

	$poe_kernel->post( $self->{session}, "proxy_post",
	$self->{http}, 'request', 'initial_request',
		HTTP::Request->new( GET => $search ), $nid );
}

sub initial_request
{
	my( $self, $req_b, $resp_b ) = @_[OBJECT,ARG0,ARG1];
	my $resp = $resp_b->[0];
	my $nid = $req_b->[1];

	#Hit a search page
	if( $resp->content =~ /IMDb\s+Search/ and $resp->content =~ /A\s+search\s+for/ )
	{
		#Find the first movie link on the page. This is an awesome hack.
		if( $resp->content =~ m{(/title/\w+)} )
		{
			my $title_uri = "$base_uri$1/";
			$self->{search}{$nid}{title_uri} = $title_uri;

			$poe_kernel->post( $self->{http}, 'request', 'parse_intro_page',
				HTTP::Request->new( GET => $title_uri ), $nid,
			);
		}
		else
		{

			warn "Bah, couldn't find anything that matched"
		}
	}
	
	#Hit the actual movie page?
	else
	{
		$poe_kernel->yield( parse_intro_page => $req_b, $resp_b );
	}
}

sub parse_intro_page
{
#  my( $self, $nid, $resp ) = @_;
  my( $self, $req_b, $resp_b ) = @_[OBJECT,ARG0,ARG1];
	my $resp = $resp_b->[0];
	my $nid = $req_b->[1];
	my $tree = HTML::TreeBuilder->new;
	$tree->parse( $resp->content );
	$tree->eof;

	my $movie_data;
	$movie_data->{title} = ($tree->look_down(_tag=>"title"))[0]->as_text;
	for( $tree->look_down( class => "ch" ) )
	{	
		my $key = $_->as_text;
		$key =~ s/:\s*$//;
		
		if( grep $key eq $_, qw/Genre Country Language Color/, )
		{
			$movie_data->{ $key } = ($_->right)[1]->as_text;
		}

		elsif( grep $key eq $_, qw/Tagline Runtime Awards/,"Plot Outline",)
		{
			$movie_data->{$key} = $_->right;
		}

		elsif( $key eq 'User Rating' )
		{
			for( $_->right )
			{
				my $string = ref $_ ? $_->as_text : $_;
				if( length $string and $string =~ /\S/ )
				{
					$movie_data->{$key}=$string;
					last;
				}
			}
		}
		elsif( $key eq "Also Known As" )
		{
			$movie_data->{$key}=($_->right)[1];
		}
	}

	$self->{info}{$nid}{front_page} = $movie_data;

	#print Dumper( $movie_data );

	my @sections = qw/fullcredits trivia goofs quotes/;
	for( @sections )
	{
		$poe_kernel->post( $self->{http}, "request", "parse_$_",
			HTTP::Request->new( GET => $self->{search}{$nid}{title_uri} . $_ ), $nid
		);
	}

	$self->{waiting_on}{$nid} = { map { $_=>1 } @sections };
}

sub parse_fullcredits
{
	my( $self, $req_b, $resp_b ) = @_[OBJECT,ARG0,ARG1];
	my $resp = $resp_b->[0];
	my $nid = $req_b->[1];

	my $tree = HTML::TreeBuilder->new;
	$tree->parse( $resp->content );
	$tree->eof;

	my $credits;
	for( $tree->look_down( class => "blackcatheader" ) )
	{
		my $table = $_->parent->parent->parent->parent; #Woo, ugly.

		my( $title, @names ) = grep $_->as_text, $table->look_down( _tag => "a" );
		$title=$title->as_text;

		if( $title eq 'Cast' )
		{
			my @contents = $table->content_list;
			#replace with shift @contents? Maybe..
			for( 0 .. $#contents )
			{
				if( $contents[$_]->look_down( _tag => 'a', sub { $_[0]->attr('href') =~ m#/name/nm# } ) )
				{
					splice( @contents, 0, $_ );
					last;
				}
			}

			for( @contents )
			{
				my $str = $_->as_text;
				my( $name, $title ) = split /\s*\Q....\E\s*/, $str;

				$credits->{Cast}->{$name} = $title;
			}		
		}

		else
		{
			@names = map $_->as_text, grep $_->attr('href') =~ m#/name/nm#, @names;

			$credits->{$title} = [ @names ];
		}
	}

#  print Dumper $credits;
	$self->{movie_info}{$nid}{full_credits} = $credits;
	$self->finished('fullcredits',$nid);
}

sub parse_quotes
{
	my( $self, $req_b, $resp_b ) = @_[OBJECT,ARG0,ARG1];
	my $resp = $resp_b->[0];
	my $nid = $req_b->[1];

	my $tree = HTML::TreeBuilder->new;
	$tree->parse( $resp->content );
	$tree->eof;
	
	my $first_link = $tree->look_down( _tag => "a", name => qr/qt\d+/ ); 
	my @quote_eles = ($first_link,$first_link->right);

	my $quotes;

	for( my $i = 0; $i < $#quote_eles; $i++ )
	{
		local $_ = $quote_eles[$i];

		if( ref $_ and $_->tag eq 'a' and $_->attr('name') =~ /qt\d+/ )
		{
			my @quote;

			my $start = $i;
			for( $i; $i < @quote_eles; $i++ )
			{
				local $_ = $quote_eles[$i];
				
				if( ref $_ and ( $_->tag eq 'hr' or $_->tag eq 'div' ) )
				{
					last;
				}

				if( ref $_ and $_->tag eq 'i' )
				{
					$quote[-1] .= $_->as_text;
					$i++;
					#Hrm, this should probably always be plain text..
					$quote[-1] .= ref $quote_eles[$i] ? $quote_eles[$i]->as_text : $quote_eles[$i];  
				}
				else
				{
					my $str = ref $_ ? $_->as_text : $_;
					if( $str =~ /\S/ ) { push @quote, $str }
				}
			}
			
			for( my $j = 0; $j < @quote; $j++ )
			{ 
				if( $quote[$j] =~ /:/ )
				{
					$quote[$j-1].=$quote[$j];
					$quote[$j]='';
				}
			}

			s/^\s+//,s/\s+$// for @quote;
			@quote = grep length $_, @quote;
			push @$quotes, \@quote;
		}
	}

	$self->{movie_info}{$nid}{quotes} = $quotes;
	$self->finished('quotes',$nid);
}

sub parse_trivia
{
	my( $self, $req_b, $resp_b ) = @_[OBJECT,ARG0,ARG1];
	my $resp = $resp_b->[0];
	my $nid = $req_b->[1];

	my $tree = HTML::TreeBuilder->new;
	$tree->parse( $resp->content );
	$tree->eof;
	
	my @trivia;
	for my $ul ($tree->look_down( _tag => "ul", class => "trivia" ) )
	{
		for( $ul->look_down( _tag => "li" ) )
		{
			push @trivia, $_->as_text;
		}
	}
		
	$self->{movie_info}{$nid}{trivia} = \@trivia;
	$self->finished('trivia',$nid);
}

sub parse_goofs
{
	my( $self, $req_b, $resp_b ) = @_[OBJECT,ARG0,ARG1];
	my $resp = $resp_b->[0];
	my $nid = $req_b->[1];

	my $tree = HTML::TreeBuilder->new;
	$tree->parse( $resp->content );
	$tree->eof;
	
	my @goofs;
	for my $ul ($tree->look_down( _tag => "ul", class => "trivia" ) ) #Yes, the class really is trivia..
	{
		for( $ul->look_down( _tag => "li" ) )
		{
			push @goofs, $_->as_text;
		}
	}
		
	$self->{movie_info}{$nid}{goofs} = \@goofs;
	$self->finished('goofs',$nid);
}

sub finished
{
	my( $self, $page, $nid ) = @_;

	delete $self->{waiting_on}{$nid}{$page};

	if( not keys %{$self->{waiting_on}{$nid}} )
	{
		$poe_kernel->post( $self->{parent_session}, imdb_FetchedMovie => $self->{movie_info}{$nid} );
	}
}


1;

__END__
=head1 NAME

POE::Component::IMDB - POE Component for interfacing with the IMDB database of films. 

=head1 SYNOPSIS

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


=head1 DESCRIPTION

This is a module created to allow easy POEish access to the IMDB. 
The interface at this point is extremely trivial.

Simply create the POE::Component::IMDB object via ->new, then call
$object->fetch_movie($movie_title). The title is then searched for
and a collection of information about the title is prepared. The
module will automatically feed your query to the search engine if
nothing matches the title exactly, and will follow the first link
the search engine returns. 

Once it has fetched and parsed all of 
interesting data about the movie, the object sends an event to 
the session where the object was instantiated, named 
"imdb_FetchedMovie". 

This event contains one argument, a reference
to a movie information object, which at this point is simply a
hash reference full of data.


=head1 SEE ALSO

POE,IMDB.com, and so forth.

=head1 AUTHOR

BUU

=head1 COPYRIGHT AND LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.0.0 or,
at your option, any later version of Perl 5 you may have available.


=cut
