package Shock;

use strict;
use warnings;
no warnings('once');

use File::Basename;
use Data::Dumper;
use JSON;
use LWP::UserAgent;

1;

sub new {
    my ($class, $shock_url, $token) = @_;
    
    my $agent = LWP::UserAgent->new;
    my $json = JSON->new;
    $json = $json->utf8();
    $json->max_size(0);
    $json->allow_nonref;
    
    my $self = {
        json => $json,
        agent => $agent,
        shock_url => $shock_url || '',
        token => $token || '',
        transport_method => 'requests'
    };
    if (system("type shock-client > /dev/null 2>&1") == 0) {
        $self->{transport_method} = 'shock-client';
    }

    bless $self, $class;
    return $self;
}

sub json {
    my ($self) = @_;
    return $self->{json};
}
sub agent {
    my ($self) = @_;
    return $self->{agent};
}
sub shock_url {
    my ($self) = @_;
    return $self->{shock_url};
}
sub token {
    my ($self) = @_;
    return $self->{token};
}
sub transport_method {
    my ($self) = @_;
    return $self->{transport_method};
}

sub _set_shockclient_auth {
    my ($self) = @_;
    
    if ($self->token && ($self->transport_method eq 'shock-client')) {
        my $auth = $self->json->encode( {"access_token" => $self->token} );
        my $msg = `shock-client auth set-token $auth`;
        if (($? >> 8) == 0) {
            return 1;
        } else {
            print STDERR "[error] setting auth token in shock-client: $msg\n";
            return 0;
        }
    } else {
        print STDERR "[error] missing token or shock-client\n";
        return 0;
    }
}


sub query { # https://github.com/MG-RAST/Shock#get_nodes
		
	my ($self, %h) = @_;
	
	my $url = $self->shock_url.'/node?query';
	
	my @pairs = %h;
	if (@pairs > 0) {
		for (my $i = 0 ; $i < @pairs ; $i+=2) {
			$url .= '&'.$pairs[$i].'='.$pairs[$i+1];
		}
	}

	#print "url: $url\n";
	
	my $response = undef;
	
	eval {
		my	$res = $self->agent->get($url, ($self->token)?('Authorization' , "OAuth ".$self->token):() );
		$response = $self->json->decode( $res->content );
	};
	#print Dumper($res);
	
	if ($@ || (! ref($response))) {
        print STDERR "[error] unable to connect to Shock ".$self->shock_url."\n";
        return undef;
    } elsif (exists($response->{error}) && $response->{error}) {
        print STDERR "[error] unable to query Shock: ".$response->{error}[0]."\n";
    } else {
        return $response;
    }
	
}

sub get_node {
    my ($self, $node) = @_;
    
    unless ($node) {
        print STDERR "[error] missing node\n";
        return undef;
    }
    
    my $content = undef;    
    eval {
        my $get = undef;
        if ($self->token) {
            $get = $self->agent->get($self->shock_url.'/node/'.$node, 'Authorization' => "OAuth ".$self->token);
        } else {
            $get = $self->agent->get($self->shock_url.'/node/'.$node);
        }
        $content = $self->json->decode($get->content);
    };
    
    if ($@ || (! ref($content))) {
        print STDERR "[error] unable to connect to Shock ".$self->shock_url."\n";
        return undef;
    } elsif (exists($content->{error}) && $content->{error}) {
        print STDERR "[error] unable to GET node $node from Shock: ".$content->{error}[0]."\n";
        return undef;
    } else {
        return $content->{data};
    }
}

sub download_to_path {
    my ($self, $node, $path) = @_;
    
    unless ($node && $path) {
        print STDERR "[error] missing node or path\n";
        return undef;
    }
    if ($self->transport_method eq 'shock-client') {
        return $self->_download_shockclient($node, $path);
    }
    
    my $content = undef;
    eval {
        my $get = undef;
        open(OUTF, ">$path") || die "Can not open file $path: $!\n";
		
		my @auth = ($self->token)?('Authorization' , "OAuth ".$self->token):();
		
        
        $get = $self->agent->get( $self->shock_url.'/node/'.$node.'?download',
                                      @auth,
                                      ':read_size_hint' => 8192,
                                      ':content_cb'     => sub{ my ($chunk) = @_; print OUTF $chunk; } );
        close OUTF;
        $content = $get->content;
    };
    
    if ($@) {
        print STDERR "[error] unable to connect to Shock ".$self->shock_url."\n";
		unlink($path);
        return undef;
    } elsif (ref($content) && exists($content->{error}) && $content->{error}) {
        print STDERR "[error] unable to GET file $node from Shock: ".$content->{error}[0]."\n";
		unlink($path);
        return undef;
    } elsif (! -s $path) {
        print STDERR "[error] unable to download to $path: $!\n";
		unlink($path);
        return undef;
    } else {
        return $path;
    }
}

sub _download_shockclient {
    my ($self, $node, $path) = @_;
    
    unless ($self->_set_shockclient_auth()) {
        return undef;
    }
    my $msg = `shock-client pdownload -threads=4 $node $path`;
    if (($? >> 8) != 0) {
        print STDERR "[error] unable to download via shock-client: $node => $path: $msg\n";
        return undef;
    }
    return $path;
}

sub create_node {
    my ($self, $data, $attr) = @_;
    return $self->upload(undef, $data, $attr);
}

#example:     upload(data => 'hello world')
#example:  or upload(file => 'myworld.txt')
#example:  or upload(file => 'myworld.txt', attr => {some hash})
# TODO implement PUT here or in another function
sub upload {
    my ($self, %hash) = @_;
	
    my $response = undef;
    my $content = {};
    my $url = $self->shock_url.'/node';
    my $method = 'POST';
    #if ($hash{'node'}) {
    #    $url = $url.'/'.$hash{'node'};
    #    $method = 'PUT';
    #}
	
	if (defined $hash{file}) {
		unless (-s $hash{file}) {
			die "file not found".$hash{'file'};
		}
		$content->{'upload'} = [$hash{'file'}]
	}
	if (defined $hash{data}) {
		$content->{'upload'} = [undef, "n/a", Content => $hash{'data'}]
	}
	
   
	if (defined $hash{'attr'}) {
		# get_handle is not good
        #$content->{attributes} = $self->_get_handle($hash{attr});
		$content->{'attributes'} = [undef, "n/a", Content => $hash{'attr'}]
    }
    
    $HTTP::Request::Common::DYNAMIC_FILE_UPLOAD = 1;
    eval {
        my $res = undef;
		my @auth = ($self->token)?('Authorization' , "OAuth ".$self->token):();
		
        if ($method eq 'POST') {
			$res = $self->agent->post($url, Content_Type => 'multipart/form-data', @auth, Content => $content);
		} else {
			$res = $self->agent->put($url, Content_Type => 'multipart/form-data', @auth, Content => $content);
        }
        $response = $self->json->decode( $res->content );
    };
    if ($@ || (! ref($response))) {
        print STDERR "[error] unable to connect to Shock ".$self->shock_url."\n";
        return undef;
    } elsif (exists($response->{error}) && $response->{error}) {
        print STDERR "[error] unable to $method data to Shock: ".$response->{error}[0]."\n";
    } else {
        return $response->{data};
    }
}


#upload multiple files/data with attribute "temporary" to shock
#argument is a hash reference:
#example: $files->{'object1'}->{'file'} = './mylocalfile.txt';
#example: $files->{'object2'}->{'data'} = 'this is data';
#it adds  $files->{'object1'}->{'node'} = <shock node id>
sub upload_temporary_files {
	my ($self, $job_input) = @_;

	
	#and upload job input to shock
	foreach my $input (keys(%$job_input)) {
		my $input_h = $job_input->{$input};
		
		
		my $attr = '{"temporary" : "1"}'; # I can find them later and delete them! ;-)
		
		my $node_obj;
		if (defined($input_h->{'file'})) {
			print "uploading ".$input_h->{'file'}." to shock...\n";
			$node_obj = $self->upload('file' => $input_h->{'file'}, 'attr' => $attr);
		} elsif (defined($input_h->{'data'})) {
			print "uploading data to shock...\n";
			$node_obj = $self->upload('data' => $input_h->{'data'}, 'attr' => $attr);
		} else {
			die "not data or file found";
		}
		
		unless (defined($node_obj)) {
			die "could not upload to shock server";
		}
		my $node = $node_obj->{'id'};
		unless (defined($node)) {
			die;
		}
		
		#print Dumper($node_obj)."\n";
		#exit(0);
		
		$input_h->{'node'} = $node;
		$input_h->{'shockhost'} = $self->shock_url();
		
	}
	
	return;
}


sub _upload_shockclient {
    my ($self, $path) = @_;
    
    unless ($self->_set_shockclient_auth()) {
        return undef;
    }
    my $msg = `shock-client pcreate -threads=4 -full $path`;
    if (($? >> 8) != 0) {
        print STDERR "[error] unable to upload via shock-client: $path: $msg\n";
        return undef;
    }
    my $res = '';
    foreach my $line (split(/\n/, $msg)) {
        chomp $line;
        if ($line !~ /Uploading/) {
            $res .= $line;
        }
    }
    return $self->json->decode($res);
}

sub _get_handle {
    my ($self, $item) = @_;
    
	eval {
		if (-s $item) {
			return [$item];
		}
	};
	# TODO: this is ugly.
	
	return [undef, "n/a", Content => $item];
}

sub delete {
    my ($self, $node) = @_;
    
	my $url = $self->shock_url.'/node/'.$node;
	my $response = undef;
	
	eval {
		my	$res = $self->agent->delete($url, ($self->token)?('Authorization' , "OAuth ".$self->token):() );
		$response = $self->json->decode( $res->content );
	};
	#print Dumper($res);
	
	if ($@ || (! ref($response))) {
        print STDERR "[error] unable to connect to Shock ".$self->shock_url."\n";
        return undef;
    } elsif (exists($response->{error}) && $response->{error}) {
        print STDERR "[error] unable to delete data from Shock: ".$response->{error}[0]."\n";
    } else {
        return $response;
    }

}

