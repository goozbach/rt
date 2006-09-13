#!/usr/bin/perl -w
# BEGIN BPS TAGGED BLOCK {{{
# 
# COPYRIGHT:
#  
# This software is Copyright (c) 1996-2004 Best Practical Solutions, LLC 
#                                          <jesse.com>
# 
# (Except where explicitly superseded by other copyright notices)
# 
# 
# LICENSE:
# 
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
# 
# 
# CONTRIBUTION SUBMISSION POLICY:
# 
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
# 
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
# 
# END BPS TAGGED BLOCK }}}

=head1 NAME

rt-mailgate - Mail interface to RT3.

=cut

use strict;
use warnings;

use Test::More tests => 68;

use RT;
RT::LoadConfig();
RT::Init();
use RT::Tickets;

use IPC::Open2;
use MIME::Entity;
use Digest::MD5;
use LWP::UserAgent;


my $url = RT->Config->Get('WebURL');

our $mailgate = $RT::BinPath .'/rt-mailgate';
die "Couldn't find mailgate ($mailgate) command" unless -f $mailgate;
$mailgate .= ' --debug';

sub run_gate {
    my %args = (
        url     => $url,
        message => '',
        action  => 'correspond',
        queue   => 'General',
        @_
    );
    my $message = delete $args{'message'};

    my $cmd = $mailgate;
    while( my ($k,$v) = each %args ) {
        next unless $v;
        $cmd .= " --$k '$v'";
    }
    $cmd .= ' 2>&1';

    DBIx::SearchBuilder::Record::Cachable->FlushCache;

    my ($child_out, $child_in);
    my $pid = open2($child_out, $child_in, $cmd);
    if ( UNIVERSAL::isa($message, 'MIME::Entity') ) {
        $message->print( $child_in );
    } else {
        print $child_in $message;
    }
    close $child_in;
    my $result = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;
    return ($?, $result);
}

sub create_ticket_via_gate {
    my $message = shift;
    my ($status, $gate_result) = run_gate( message => $message, @_ );
    my $id;
    unless ( $status >> 8 ) {
        ($id) = ($gate_result =~ /Ticket:\s*(\d+)/i);
        unless ( $id ) {
            diag "Couldn't find ticket id in text:\n$gate_result" if $ENV{'TEST_VERBOSE'};
        }
    }
    return ($status, $id);
}

sub latest_ticket {
    my $tickets = RT::Tickets->new( $RT::SystemUser );
    $tickets->OrderBy( FIELD => 'id', ORDER => 'DESC' );
    $tickets->Limit( FIELD => 'id', OPERATOR => '>', VALUE => '0' );
    $tickets->RowsPerPage( 1 );
    return $tickets->First;
}

diag "Make sure that when we call the mailgate without URL, it fails" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: root\@localhost
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of new ticket creation

Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text, url => undef);
    is ($status >> 8, 1, "The mail gateway exited with a failure");
    ok (!$id, "No ticket id") or diag "by mistake ticket #$id";
}

diag "Make sure that when we call the mailgate with wrong --extension, it fails" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: root\@localhost
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of new ticket creation

Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text, extension => 'bad-extension-arg' );
    is ($status >> 8, 1, "The mail gateway exited with a failure");
    ok (!$id, "No ticket id") or diag "by mistake ticket #$id";
}

diag "Make sure that when we call the mailgate with wrong URL, it tempfails" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: root\@localhost
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of new ticket creation

Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text, url => 'http://this.test.for.non-connection.is.expected.to.generate.an.error');
    is ($status >> 8, 75, "The mail gateway exited with a failure");
    ok (!$id, "No ticket id");
}

my $everyone_group;
diag "revoke rights tests depend on";
{
    $everyone_group = RT::Group->new( $RT::SystemUser );
    $everyone_group->LoadSystemInternalGroup( 'Everyone' );
    ok ($everyone_group->Id, "Found group 'everyone'");

    foreach( qw(CreateTicket ReplyToTicket CommentOnTicket) ) {
        $everyone_group->PrincipalObj->RevokeRight(Right => $_);
    }
}

diag "Test new ticket creation by root who is privileged and superuser" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: root\@localhost
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of new ticket creation

Blah!
Foob!
EOF

    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "Created ticket");

    my $tick = latest_ticket();
    isa_ok ($tick, 'RT::Ticket');
    ok ($tick->Id, "found ticket");
    is ($tick->Id, $id, "correct ticket id");
    ok ($tick->Subject eq 'This is a test of new ticket creation', "Created the ticket");
}

diag "This is a test of new ticket creation as an unknown user" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: doesnotexist\@@{[RT->Config->Get('rtname')]}
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of new ticket creation as an unknown user

Blah!
Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok (!$id, "no ticket created");

    my $tick = latest_ticket();
    isa_ok ($tick, 'RT::Ticket');
    ok ($tick->Id, "found ticket ".$tick->Id);
    ok ($tick->Subject ne 'This is a test of new ticket creation as an unknown user', "failed to create the new ticket from an unprivileged account");

    my $u = RT::User->new($RT::SystemUser);
    $u->Load("doesnotexist\@@{[RT->Config->Get('rtname')]}");
    ok( !$u->Id, "user does not exist and was not created by failed ticket submission");
}

diag "grant everybody with CreateTicket right";
{
    my ($val, $msg) = $everyone_group->PrincipalObj->GrantRight( Right => 'CreateTicket' );
    ok ($val, "Granted everybody the right to create tickets") or diag "error: $msg";
}

my $ticket_id;
diag "now everybody can create tickets. can a random unkown user create tickets?" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: doesnotexist\@@{[RT->Config->Get('rtname')]}
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of new ticket creation as an unknown user

Blah!
Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "ticket created");

    my $tick = latest_ticket();
    isa_ok ($tick, 'RT::Ticket');
    ok ($tick->Id, "found ticket ".$tick->Id);
    is ($tick->Id, $id, "correct ticket id");
    ok ($tick->Subject eq 'This is a test of new ticket creation as an unknown user', "failed to create the new ticket from an unprivileged account");

    my $u = RT::User->new( $RT::SystemUser );
    $u->Load( "doesnotexist\@@{[RT->Config->Get('rtname')]}" );
    ok ($u->Id, "user does not exist and was created by ticket submission");
    $ticket_id = $id;
}

diag "can another random reply to a ticket without being granted privs? answer should be no." if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: doesnotexist-2\@@{[RT->Config->Get('rtname')]}
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: [@{[RT->Config->Get('rtname')]} #$ticket_id] This is a test of a reply as an unknown user

Blah!  (Should not work.)
Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok (!$id, "no way to reply to the ticket");

    my $u = RT::User->new($RT::SystemUser);
    $u->Load('doesnotexist-2@'.RT->Config->Get('rtname'));
    ok( !$u->Id, " user does not exist and was not created by ticket correspondence submission");
}

diag "grant everyone 'ReplyToTicket' right" if $ENV{'TEST_VERBOSE'};
{
    my ($val,$msg) = $everyone_group->PrincipalObj->GrantRight(Right => 'ReplyToTicket');
    ok ($val, "Granted everybody the right to reply to  tickets - $msg");
}

diag "can another random reply to a ticket after being granted privs? answer should be yes" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: doesnotexist-2\@@{[RT->Config->Get('rtname')]}
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: [@{[RT->Config->Get('rtname')]} #$ticket_id] This is a test of a reply as an unknown user

Blah!
Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    is ($id, $ticket_id, "replied to the ticket");

    my $u = RT::User->new($RT::SystemUser);
    $u->Load('doesnotexist-2@'.RT->Config->Get('rtname'));
    ok ($u->Id, "user exists and was created by ticket correspondence submission");
}


diag "can another random comment on a ticket without being granted privs? answer should be no" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: doesnotexist-3\@@{[RT->Config->Get('rtname')]}
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: [@{[RT->Config->Get('rtname')]} #$ticket_id] This is a test of a comment as an unknown user

Blah!  (Should not work.)
Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text, action => 'comment');
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok (!$id, "no way to comment on the ticket");

    my $u = RT::User->new($RT::SystemUser);
    $u->Load('doesnotexist-3@'.RT->Config->Get('rtname'));
    ok( !$u->Id, " user does not exist and was not created by ticket comment submission");
}


diag "grant everyone 'ReplyToTicket' right" if $ENV{'TEST_VERBOSE'};
{
    my ($val,$msg) = $everyone_group->PrincipalObj->GrantRight(Right => 'CommentOnTicket');
    ok ($val, "Granted everybody the right to reply to  tickets - $msg");
}

diag "can another random reply to a ticket after being granted privs? answer should be yes" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: doesnotexist-3\@@{[RT->Config->Get('rtname')]}
To: rt\@@{[RT->Config->Get('rtname')]}
Subject: [@{[RT->Config->Get('rtname')]} #$ticket_id] This is a test of a comment as an unknown user

Blah!
Foob!
EOF
    my ($status, $id) = create_ticket_via_gate($text, action => 'comment');
    is ($status >> 8, 0, "The mail gateway exited normally");
    is ($id, $ticket_id, "replied to the ticket");

    my $u = RT::User->new($RT::SystemUser);
    $u->Load('doesnotexist-3@'.RT->Config->Get('rtname'));
    ok ($u->Id, " user exists and was created by ticket comment submission");
}

diag "Testing preservation of binary attachments" if $ENV{'TEST_VERBOSE'};
{
    # Get a binary blob (Best Practical logo) 
    my $LOGO_FILE = $RT::MasonComponentRoot .'/NoAuth/images/bplogo.gif';

    # Create a mime entity with an attachment
    my $entity = MIME::Entity->build(
        From    => 'root@localhost',
        To      => 'rt@localhost',
        Subject => 'binary attachment test',
        Data    => ['This is a test of a binary attachment'],
    );

    $entity->attach(
        Path     => $LOGO_FILE,
        Type     => 'image/gif',
        Encoding => 'base64',
    );
    # Create a ticket with a binary attachment
    my ($status, $id) = create_ticket_via_gate($entity);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "created ticket");

    my $tick = latest_ticket();
    isa_ok ($tick, 'RT::Ticket');
    ok ($tick->Id, "found ticket ".$tick->Id);
    is ($tick->Id, $id, "correct ticket id");
    ok ($tick->Subject eq 'binary attachment test', "Created the ticket - ".$tick->Id);

    my $file = `cat $LOGO_FILE`;
    ok ($file, "Read in the logo image");
    diag "for the raw file the md5 hex is ". Digest::MD5::md5_hex($file) if $ENV{'TEST_VERBOSE'};

    # Verify that the binary attachment is valid in the database
    my $attachments = RT::Attachments->new($RT::SystemUser);
    $attachments->Limit(FIELD => 'ContentType', VALUE => 'image/gif');
    my $txn_alias = $attachments->Join(
        ALIAS1 => 'main',
        FIELD1 => 'TransactionId',
        TABLE2 => 'Transactions',
        FIELD2 => 'id',
    );
    $attachments->Limit( ALIAS => $txn_alias, FIELD => 'ObjectType', VALUE => 'RT::Ticket' );
    $attachments->Limit( ALIAS => $txn_alias, FIELD => 'ObjectId', VALUE => $id );
    is ($attachments->Count, 1, 'Found only one gif attached to the ticket');
    my $attachment = $attachments->First;
    ok ($attachment->Id, 'loaded attachment object');
    my $acontent = $attachment->Content;

    diag "coming from the database, md5 hex is ".Digest::MD5::md5_hex($acontent) if $ENV{'TEST_VERBOSE'};
    is ($acontent, $file, 'The attachment isn\'t screwed up in the database.');

    # Grab the binary attachment via the web ui
    my $ua = new LWP::UserAgent;
    my $full_url = "$url/Ticket/Attachment/". $attachment->TransactionId
        ."/". $attachment->id. "/bplogo.gif?&user=root&pass=password";
    my $r = $ua->get( $full_url );

    # Verify that the downloaded attachment is the same as what we uploaded.
    is ($file, $r->content, 'The attachment isn\'t screwed up in download');
}

diag "Simple I18N testing" if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: root\@localhost
To: rtemail\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of I18N ticket creation
Content-Type: text/plain; charset="utf-8"

2 accented lines
\303\242\303\252\303\256\303\264\303\273
\303\241\303\251\303\255\303\263\303\272
bye
EOF
    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "created ticket");

    my $tick = latest_ticket();
    isa_ok ($tick, 'RT::Ticket');
    ok ($tick->Id, "found ticket ". $tick->Id);
    is ($tick->Id, $id, "correct ticket");
    ok ($tick->Subject eq 'This is a test of I18N ticket creation', "Created the ticket - ". $tick->Subject);

    my $unistring = "\303\241\303\251\303\255\303\263\303\272";
    Encode::_utf8_on($unistring);
    is (
        $tick->Transactions->First->Content,
        $tick->Transactions->First->Attachments->First->Content,
        "Content is ". $tick->Transactions->First->Attachments->First->Content
    );
    ok (
        $tick->Transactions->First->Content =~ /$unistring/i,
        $tick->Id." appears to be unicode ". $tick->Transactions->First->Attachments->First->Id
    );
}

diag "supposedly I18N fails on the second message sent in." if $ENV{'TEST_VERBOSE'};
{
    my $text = <<EOF;
From: root\@localhost
To: rtemail\@@{[RT->Config->Get('rtname')]}
Subject: This is a test of I18N ticket creation
Content-Type: text/plain; charset="utf-8"

2 accented lines
\303\242\303\252\303\256\303\264\303\273
\303\241\303\251\303\255\303\263\303\272
bye
EOF
    my ($status, $id) = create_ticket_via_gate($text);
    is ($status >> 8, 0, "The mail gateway exited normally");
    ok ($id, "created ticket");

    my $tick = latest_ticket();
    isa_ok ($tick, 'RT::Ticket');
    ok ($tick->Id, "found ticket ". $tick->Id);
    is ($tick->Id, $id, "correct ticket");
    ok ($tick->Subject eq 'This is a test of I18N ticket creation', "Created the ticket");

    my $unistring = "\303\241\303\251\303\255\303\263\303\272";
    Encode::_utf8_on($unistring);

    ok (
        $tick->Transactions->First->Content =~ $unistring,
        "It appears to be unicode - ". $tick->Transactions->First->Content
    );
}


my ($val,$msg) = $everyone_group->PrincipalObj->RevokeRight(Right => 'CreateTicket');
ok ($val, $msg);

=for later

TODO: {

# {{{ Check take and resolve actions

# create ticket that is owned by nobody
use RT::Ticket;
$tick = RT::Ticket->new($RT::SystemUser);
my ($id) = $tick->Create( Queue => 'general', Subject => 'test');
ok( $id, 'new ticket created' );
is( $tick->Owner, $RT::Nobody->Id, 'owner of the new ticket is nobody' );

ok(open(MAIL, "|$RT::BinPath/rt-mailgate --url $url --queue general --action take"), "Opened the mailgate - $@");
print MAIL <<EOF;
From: root\@localhost
Subject: [@{[RT->Config->Get('rtname')]} \#$id] test

EOF
close (MAIL);
is ($? >> 8, 0, "The mail gateway exited normally");

$tick = RT::Ticket->new($RT::SystemUser);
$tick->Load( $id );
is( $tick->Id, $id, 'load correct ticket');
is( $tick->OwnerObj->EmailAddress, 'root@localhost', 'successfuly take ticket via email');

# check that there is no text transactions writen
is( $tick->Transactions->Count, 2, 'no superfluous transactions');

($status, $msg) = $tick->SetOwner( $RT::Nobody->Id, 'Force' );
ok( $status, 'successfuly changed owner: '. ($msg||'') );
is( $tick->Owner, $RT::Nobody->Id, 'set owner back to nobody');


local $TODO = "Advanced mailgate actions require an unsafe configuration";
ok(open(MAIL, "|$RT::BinPath/rt-mailgate --url $url --queue general --action take-correspond"), "Opened the mailgate - $@");
print MAIL <<EOF;
From: root\@localhost
Subject: [@{[RT->Config->Get('rtname')]} \#$id] correspondence

test
EOF
close (MAIL);
is ($? >> 8, 0, "The mail gateway exited normally");

$tick = RT::Ticket->new($RT::SystemUser);
$tick->Load( $id );
is( $tick->Id, $id, 'load correct ticket');
is( $tick->OwnerObj->EmailAddress, 'root@localhost', 'successfuly take ticket via email');
my $txns = $tick->Transactions;
$txns->Limit( FIELD => 'Type', VALUE => 'Correspond');
is( $txns->Last->Subject, "[@{[RT->Config->Get('rtname')]} \#$id] correspondence", 'successfuly add correspond within take via email' );
# +1 because of auto open
is( $tick->Transactions->Count, 6, 'no superfluous transactions');

ok(open(MAIL, "|$RT::BinPath/rt-mailgate --url $url --queue general --action resolve --debug"), "Opened the mailgate - $@");
print MAIL <<EOF;
From: root\@localhost
Subject: [@{[RT->Config->Get('rtname')]} \#$id] test

EOF
close (MAIL);
is ($? >> 8, 0, "The mail gateway exited normally");

DBIx::SearchBuilder::Record::Cachable->FlushCache;

$tick = RT::Ticket->new($RT::SystemUser);
$tick->Load( $id );
is( $tick->Id, $id, 'load correct ticket');
is( $tick->Status, 'resolved', 'successfuly resolved ticket via email');
is( $tick->Transactions->Count, 7, 'no superfluous transactions');

};

=cut

# }}}

1;
