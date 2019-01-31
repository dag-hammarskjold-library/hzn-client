use v5.10;
use strict;
use warnings;

# Parent class for MARC exports

package Hzn::Export;
use Moo;
use Carp qw<confess>;
use DateTime;
use List::Util qw<any>;
use Time::HiRes qw<gettimeofday>;
use Data::Dumper;

use Utils qw<date_unix_8601>;

use Hzn::Export::Util::AuditData;
use Hzn::Export::Util::ItemData;
use Hzn::Util::Modified;

use Hzn::SQL;
use Hzn::SQL::MARC::Bib;
use Hzn::SQL::MARC::Auth;

use constant OUTPUT_TYPES => { map {$_ => 1} qw<xml json mrc mrk mongo> };

use constant XML_HEADER => <<'#';
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE marc [
	<!ELEMENT collection (record*)>
	<!ATTLIST collection xmlns CDATA "">
	<!ELEMENT record (leader,controlfield+,datafield+)>
	<!ELEMENT leader (#PCDATA)>stat
	<!ELEMENT controlfield (#PCDATA)>
	<!ATTLIST controlfield tag CDATA "">
	<!ELEMENT datafield (subfield+)>
	<!ATTLIST datafield tag CDATA "" ind1 CDATA "" ind2 CDATA "">
	<!ELEMENT subfield (#PCDATA)>
	<!ATTLIST subfield code CDATA ""> 
]>
#

has 'export_id', is => 'ro', builder => sub {date_unix_8601(time)};

has 'sql_criteria', is => 'rw';

has 'modified_since', is => 'rw'; #, default => DateTime->now->ymd('');
has 'modified_until', is => 'rw'; #, default => DateTime->now->ymd('');

has 'ids_to_export' => (
	is => 'ro',
	lazy => 1,
	builder => sub {
		my $self = shift;
		if (my $from = $self->modified_since) {
			my $to = $self->modified_until;
			return [ Hzn::Util::Modified->new(marc_type => $self->marc_type)->since(from => $from,to => $to) ];
		}
		return [ map {$_->[0]} Hzn::SQL->new(statement => $self->sql_criteria)->run ];
	}
);

#has 'include_tags', is => 'rw';
has 'exclude_tags', is => 'rw', default => sub {[]};

has 'output_type' => (
	is => 'rw',
	isa => sub {
		die unless OUTPUT_TYPES->{$_[0]};
	},
	lazy => 1,
	builder => sub {
		my $self = shift;
		
		if ($self->mongodb_collection_handle) {
			return 'mongo',
		} else {
			# default
			return 'xml'
		}
	}	
);

has 'mongodb_collection_handle' => (
	is => => 'rw',
	isa => sub {
		die unless ref $_[0] eq 'MongoDB::Collection'; 		
	}
); 

has 'serializer' => (
	is => 'ro', 
	lazy => 1, 
	builder => sub {
		my $self = shift; 
		return 'to_'.$self->output_type;
	}
);

has 'output_directory', is => 'rw', isa => sub {die unless -e $_[0]}, default => '.',;
has 'output_filename', is => 'rw';

has 'output_handle' => (
	is => 'ro',
	lazy => 1,
	builder => sub {
		my $self = shift;
		
		my $h;
		if ($self->output_filename) {
			open $h,'>:utf8', join('/',$self->output_directory,$self->output_filename) or confess $!;
		} else {
			$h = *STDOUT;
		}
		
		return $h;
	}
);	

has 'files_database', is => 'rw';

has '_chars_to_delete', is => 'rw', default => 0;

### stubs

has 'marc_type' => (
	is => 'ro',
	default => sub {die 'attribute "marc_type" must be provided by subclass'}
);

sub _exclude {
	die 'method "_exclude" must be provided by subclass';
}

sub _xform {
	die 'method "_xform" must be provided by subclass';
}

###

sub BUILD {
	my $self = shift;
	
	#say $self->sql_criteria;
}

##

sub run {
	my $self = shift;
	
	die q{Attribute "sql_criteria" or "modified_since" must be set}."\n" unless $self->sql_criteria || $self->modified_since;
	
	local $| = 1;
	
	my $ids = $self->ids_to_export;
	my ($status,$current,$wrote,$total) = ('',0,0,scalar @$ids);
	my $t = gettimeofday;
	
	print "processing: ";
	
	while (@$ids) {
		
		my @batch = splice @$ids,0,1000;
		
		my $audit = Hzn::Export::Util::AuditData->new(type => lc $self->marc_type, filter => \@batch);
		my $item = $self->marc_type eq 'Bib' ? Hzn::Export::Util::ItemData->new(filter => \@batch) : undef;
				
		if ($self->output_type eq 'xml') {
			say {$self->output_handle} XML_HEADER."\n<collection>";
		}

		my $iterable = 'Hzn::SQL::MARC::'.$self->marc_type;
		$iterable->new->iterate (
			encoding => 'utf8',
			criteria => join(',',@batch),
			callback => sub {
				my $record = shift;
		
				$current++;
			
				if ($current == $total || $current % 5 == 0 && ($self->output_filename || $self->mongodb_collection_handle)) {
					$self->_update_status($current,$total);
				}
				
				return if $self->_exclude($record);
				$self->_xform($record,$audit,$item);
				INC: {
					# todo
					next;
				}
				EXC: {
					$record->delete_tag($_) for @{$self->exclude_tags};
				}
				
				$self->_write($record);
				
				$wrote++;
			}
		);
		
		if ($self->output_type eq 'xml') {
			print {$self->output_handle} '</collection>';;
		}
	}
	
	print "\n";
	say "wrote $wrote records in ".(gettimeofday - $t).' seconds';
}

###

sub _write {
	my ($self,$record) = @_;
	
	if (any {$_ eq $self->output_type} qw<xml mrk marc21>) {
		my $serializer = $self->serializer;
		print {$self->output_handle} $record->$serializer;
	} elsif ($self->mongodb_collection_handle) {
		$record->to_mongo($self->mongodb_collection_handle);
	}
}

sub _update_status {
	my ($self,$current,$total) = @_;
	print "\b" x $self->_chars_to_delete;
	my $status = "$current / $total ";
	print $status;
	$self->_chars_to_delete(length $status);
}

###

1;