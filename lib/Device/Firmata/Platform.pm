package Device::Firmata::Platform;

use strict;
use Time::HiRes qw/time/;
use Device::Firmata::Constants qw/ :all /;
use Device::Firmata::IO;
use Device::Firmata::Protocol;
use Device::Firmata::Base
    ISA => 'Device::Firmata::Base',
    FIRMATA_ATTRIBS => {

# Object handlers
        io               => undef,
        protocol         => undef,

# Used for internal tracking of events/parameters
        protocol_version => undef,
        sysex_mode       => undef,
        sysex_data       => [],

# To track internal status
        ports            => [],
        analog_pins      => [],
        pins             => {},

# For information about the device. eg: firmware version
        metadata         => {},
    };

sub open {
# --------------------------------------------------
# Connect to the IO port and do some basic operations
# to find out how to connect to the device
#
    my ( $pkg, $port, $opts ) = @_;

    my $self = ref $pkg ? $pkg : $pkg->new($opts);

    $self->{io}       = Device::Firmata::IO->open($port,$opts) or return;
    $self->{protocol} = Device::Firmata::Protocol->new($opts)  or return;

    return $self;
}

sub messages_handle {
# --------------------------------------------------
# Receive identified message packets and convert them
# into their appropriate structures and parse
# them as required
#
    my ( $self, $messages ) = @_;

    return unless $messages;
    return unless @$messages;

# Now, handle the messages
    my $proto  = $self->{protocol};
    for my $message ( @$messages ) {
        my $command = $message->{command_str};
        my $data    = $message->{data};

        COMMAND_HANDLE: {

# Handle pin messages
            $command eq 'DIGITAL_MESSAGE' and do {
                my $port_number = $message->{command} & 0x0f;
                my $port_state  = $data->[0] | ($data->[1] << 7);
                $self->{ports}[$port_number] = $port_state;
            };

# Handle analog pin messages
            $command eq 'ANALOG_MESSAGE' and do {
                my $pin_number = $message->{command} & 0x0f;
                my $pin_value = ( $data->[0] | ($data->[1] << 7) ) / 1023;
                $self->{analog_pins}[$pin_number] = $pin_value;
            };


# Handle metadata information
            $command eq 'REPORT_VERSION' and do {
                $self->{metadata}{firmware_version} = sprintf "V_%i_%02i", @$data;
                last;
            };

# SYSEX handling
            $command eq 'START_SYSEX' and do {
                last;
            };
            $command eq 'DATA_SYSEX' and do {
                my $sysex_data = $self->{sysex_data};
                push @$sysex_data, @$data;
                last;
            };
            $command eq 'END_SYSEX' and do {
                my $sysex_data = $self->{sysex_data};
                my $sysex_message = $proto->sysex_parse($sysex_data);
                $self->sysex_handle($sysex_message);
                $self->{sysex_data} = [];
                last;
            };

        };
 
        $Device::Firmata::DEBUG and print "    < $command\n";
    }

}

sub sysex_handle {
# --------------------------------------------------
# Receive identified sysex packets and convert them
# into their appropriate structures and parse
# them as required
#
    my ( $self, $sysex_message ) = @_;

    my $data = $sysex_message->{data};

    $sysex_message->{command_str} eq 'REPORT_FIRMWARE' and do {
        $self->{metadata}{firmware_version} = sprintf "V_%i_%02i", $data->[0], $data->[1];
        $self->{metadata}{firmware} = $data->[2];
        return;
    };
}

sub probe {
# --------------------------------------------------
# Request the version of the protocol that the
# target device is using. Sometimes, we'll have to
# wait a couple of seconds for the response so we'll
# try for 2 seconds and rapidly fire requests if 
# we don't get a response quickly enough ;)
#
    my ( $self ) = @_;

    my $proto  = $self->{protocol};
    my $io     = $self->{io};
    $self->{metadata}{firmware_version} = '';

# Wait for 10 seconds only
    my $end_tics = time + 10;

# Query every .5 seconds
    my $query_tics = time;
    while ( $end_tics >= time ) {

        if ( $query_tics <= time ) {
# Query the device for information on the firmata firmware_version
            my $query_packet = $proto->packet_query_version;
            $io->data_write($query_packet) or die "OOPS: $!";
            $query_tics = time + 0.5;
        };

# Try to get a response
        my $buf = $io->data_read(100) or do {
                        select undef, undef, undef, 0.1;
                        next;
                    };
        my $messages = $proto->message_data_receive($buf);

# Start handling the messages
        $self->messages_handle($messages);

        if ( $self->{metadata}{firmware_version} ) {
            return $self->{metadata}{firmware_version};
        }
    }
}

sub pin_mode {
# --------------------------------------------------
# Similar to the pinMode function on the 
# arduino
# 
    my ( $self, $pin, $mode ) = @_;

    if ( $mode == PIN_INPUT or $mode == PIN_OUTPUT ) {
        my $port_number = $pin >> 3;
        my $mode_packet = $self->{protocol}->message_prepare( REPORT_DIGITAL => $port_number, 1 );
        $self->{io}->data_write($mode_packet);

        my $mode_packet = $self->{protocol}->message_prepare( SET_PIN_MODE => 0, $pin, $mode );
        return $self->{io}->data_write($mode_packet);
    }

    elsif ( $mode == PIN_PWM ) {
        my $mode_packet = $self->{protocol}->message_prepare( SET_PIN_MODE => 0, $pin, $mode );
        return $self->{io}->data_write($mode_packet);
    }

    elsif ( $mode == PIN_ANALOG ) {
        my $port_number = $pin >> 3;
        my $mode_packet = $self->{protocol}->message_prepare( REPORT_ANALOG => $port_number, 1 );
        $self->{io}->data_write($mode_packet);

        my $mode_packet = $self->{protocol}->message_prepare( SET_PIN_MODE => 0, $pin, $mode );
        return $self->{io}->data_write($mode_packet);
    }

}

sub digital_write {
# --------------------------------------------------
# Analogous to the digitalWrite function on the 
# arduino
#
    my ( $self, $pin, $state ) = @_;
    my $port_number = $pin >> 3;

    my $pin_offset  = $pin % 8;
    my $pin_mask    = 1<<$pin_offset;

    my $port_state  = $self->{ports}[$port_number] ||= 0;
    if ( $state ) {
        $port_state |= $pin_mask;
    }
    else {
        $port_state &= $pin_mask ^ 0xff;
    }
    $self->{ports}[$port_number] = $port_state;

    my $mode_packet = $self->{protocol}->message_prepare( DIGITAL_MESSAGE => $port_number, $port_state);
    return $self->{io}->data_write($mode_packet);
}

sub digital_read {
# --------------------------------------------------
# Analogous to the digitalRead function on the 
# arduino
# 
    my ( $self, $pin ) = @_;
    my $port_number = $pin >> 3;
    my $pin_offset  = $pin % 8;
    my $pin_mask    = 1<<$pin_offset;
    my $port_state = $self->{ports}[$port_number] ||= 0;
    return( $port_state & $pin_mask ? 1 : 0 );
}

sub analog_read {
# --------------------------------------------------
# Fetches the analog value of a pin 
#
    my ( $self, $pin ) = @_;
    return $self->{analog_pins}[$pin];
}

sub analog_write {
# --------------------------------------------------
# Sets the PWM value on an arduino
#
    my ( $self, $pin, $value ) = @_;

# FIXME: 8 -> 7 bit translation should be done in the protocol module
    my $byte_0 = $value & 0x7f;
    my $byte_1 = $value >> 7;
    my $mode_packet = $self->{protocol}->message_prepare( ANALOG_MESSAGE => $pin, $byte_0, $byte_1 );
    return $self->{io}->data_write($mode_packet);
}
*pwm_write = *analog_write;

sub poll {
# --------------------------------------------------
# Call this function every once in a while to
# check up on the status of the comm port, receive
# and process data from the arduino
#
    my $self = shift;
    my $buf = $self->{io}->data_read(100) or return;
    my $messages = $self->{protocol}->message_data_receive($buf);
    $self->messages_handle($messages);
    return $messages;
}

1;
