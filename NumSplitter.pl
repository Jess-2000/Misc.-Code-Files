use strict;
use warnings;
use utf8;

use File::Basename qw(dirname basename);
use File::Copy qw(copy move);
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long qw(GetOptions);

use constant TARGET_FIELD     => 'SBJ_ID';
use constant MIN_SPLIT_LENGTH => 20;
use constant MAX_CHUNK_LENGTH => 15;
use constant CHUNK_SEPARATOR  => ' ';

my $backup  = 0;
my $dry_run = 0;
my $help    = 0;

GetOptions(
    'backup!' => \$backup,
    'dry-run' => \$dry_run,
    'help|h'  => \$help,
) or usage(1);

usage(0) if $help;

my $filename = shift @ARGV;
usage(1) if !defined $filename || @ARGV;

die "File not found: $filename\n" unless -f $filename;
die "File is not a text file: $filename\n" unless -T $filename;

my $absolute_filename = File::Spec->rel2abs($filename);
my $directory         = dirname($absolute_filename);
my $original_name     = basename($absolute_filename);

open my $in_fh, '<:encoding(UTF-8)', $absolute_filename
    or die "Could not open '$absolute_filename': $!\n";

my $header_line = <$in_fh>;
die "Input file is empty: $absolute_filename\n" unless defined $header_line;

my $line_ending = detect_line_ending($header_line);
$header_line =~ s/\r?\n\z//;

my @headers = split /\|/, $header_line, -1;
my $target_index = find_column_index(\@headers, TARGET_FIELD);

die "Required field '" . TARGET_FIELD . "' was not found in the header.\n"
    unless defined $target_index;

my $expected_fields = scalar @headers;
my $line_number     = 1;
my $records_seen    = 0;
my $records_changed = 0;
my $records_unchanged = 0;
my $records_rejected  = 0;

my ($out_fh, $temp_filename);

unless ($dry_run) {
    ($out_fh, $temp_filename) = tempfile(
        'numsplitter-XXXXXX',
        DIR    => $directory,
        SUFFIX => '.tmp',
        UNLINK => 0,
    );

    binmode $out_fh, ':encoding(UTF-8)';
    print {$out_fh} $header_line, $line_ending
        or die "Could not write temporary file '$temp_filename': $!\n";
}

while (my $raw_line = <$in_fh>) {
    ++$line_number;
    ++$records_seen;

    my $record_ending = detect_line_ending($raw_line) || $line_ending;
    $raw_line =~ s/\r?\n\z//;

    my ($fields_ref, $parse_error) = split_csv_raw($raw_line);

    if (defined $parse_error) {
        ++$records_rejected;
        warn sprintf(
            "WARNING: Line %d could not be parsed as CSV (%s). Record left unchanged.\n",
            $line_number,
            $parse_error,
        );

        unless ($dry_run) {
            print {$out_fh} $raw_line, $record_ending
                or die "Could not write temporary file '$temp_filename': $!\n";
        }
        next;
    }

    my @raw_fields = @$fields_ref;

    if (@raw_fields != $expected_fields) {
        ++$records_rejected;
        warn sprintf(
            "WARNING: Line %d contains %d fields; expected %d. Record left unchanged.\n",
            $line_number,
            scalar(@raw_fields),
            $expected_fields,
        );

        unless ($dry_run) {
            print {$out_fh} $raw_line, $record_ending
                or die "Could not write temporary file '$temp_filename': $!\n";
        }
        next;
    }

    my $original_raw_id = $raw_fields[$target_index];
    my $original_id     = decode_csv_field($original_raw_id);
    my ($new_id, $status) = transform_sbj_id($original_id);

    if ($status eq 'changed') {
        $raw_fields[$target_index] = encode_replacement_like_original($original_raw_id, $new_id);
        ++$records_changed;
    }
    elsif ($status eq 'invalid') {
        ++$records_rejected;
        warn sprintf(
            "WARNING: Line %d has an unexpected %s value '%s'. Record left unchanged.\n",
            $line_number,
            TARGET_FIELD,
            display_value($original_id),
        );

        unless ($dry_run) {
            print {$out_fh} $raw_line, $record_ending
                or die "Could not write temporary file '$temp_filename': $!\n";
        }
        next;
    }
    else {
        ++$records_unchanged;
    }

    unless ($dry_run) {
        print {$out_fh} join(',', @raw_fields), $record_ending
            or die "Could not write temporary file '$temp_filename': $!\n";
    }
}

close $in_fh
    or die "Could not close '$absolute_filename': $!\n";

if (!$dry_run) {
    close $out_fh
        or die "Could not close temporary file '$temp_filename': $!\n";

    my $mode = (stat $absolute_filename)[2] & 07777;
    chmod $mode, $temp_filename
        or die "Could not preserve permissions on '$temp_filename': $!\n";

    if ($backup) {
        my $backup_filename = $absolute_filename . '.bak';
        copy($absolute_filename, $backup_filename)
            or die "Could not create backup '$backup_filename': $!\n";
    }

    move($temp_filename, $absolute_filename)
        or die "Could not replace '$absolute_filename': $!\n";
}

print "Processing complete.\n";
print "  File: $original_name\n";
print "  Records read: $records_seen\n";
print "  " . TARGET_FIELD . " values changed: $records_changed\n";
print "  Records unchanged: $records_unchanged\n";
print "  Records rejected: $records_rejected\n";
print "  Mode: " . ($dry_run ? 'dry run (no file changes)' : 'file updated') . "\n";
print "  Backup: " . ($backup && !$dry_run ? 'created' : 'not created') . "\n";

sub find_column_index {
    my ($headers_ref, $column_name) = @_;

    for my $index (0 .. $#$headers_ref) {
        return $index if $headers_ref->[$index] eq $column_name;
    }

    return undef;
}

sub transform_sbj_id {
    my ($value) = @_;

    return ($value, 'unchanged') unless defined $value && length $value;

    # Already split correctly: normalize nothing and leave it exactly as supplied.
    if ($value =~ /^\d+(?: \d+)+$/) {
        my @parts = split / /, $value, -1;

        return ($value, 'invalid')
            if grep { length($_) > MAX_CHUNK_LENGTH } @parts;

        my $combined = join '', @parts;
        return ($value, 'invalid') unless length($combined) >= MIN_SPLIT_LENGTH;

        return ($value, 'unchanged');
    }

    return ($value, 'invalid') unless $value =~ /^\d+$/;
    return ($value, 'unchanged') if length($value) < MIN_SPLIT_LENGTH;

    return (split_number_balanced($value), 'changed');
}

sub split_number_balanced {
    my ($number) = @_;

    my $length = length $number;
    my $chunk_count = int(($length + MAX_CHUNK_LENGTH - 1) / MAX_CHUNK_LENGTH);
    my $base_size   = int($length / $chunk_count);
    my $remainder   = $length % $chunk_count;

    my @parts;
    my $position = 0;

    for my $index (0 .. $chunk_count - 1) {
        my $chunk_size = $base_size + ($index < $remainder ? 1 : 0);
        push @parts, substr($number, $position, $chunk_size);
        $position += $chunk_size;
    }

    return join CHUNK_SEPARATOR, @parts;
}

sub split_csv_raw {
    my ($line) = @_;

    my @fields;
    my $field = '';
    my $in_quotes = 0;
    my $index = 0;
    my $length = length $line;

    while ($index < $length) {
        my $char = substr($line, $index, 1);

        if ($char eq '"') {
            if ($in_quotes && $index + 1 < $length && substr($line, $index + 1, 1) eq '"') {
                $field .= '""';
                $index += 2;
                next;
            }

            $in_quotes = !$in_quotes;
            $field .= $char;
            ++$index;
            next;
        }

        if ($char eq ',' && !$in_quotes) {
            push @fields, $field;
            $field = '';
            ++$index;
            next;
        }

        $field .= $char;
        ++$index;
    }

    return (undef, 'unclosed quoted field') if $in_quotes;

    push @fields, $field;
    return (\@fields, undef);
}

sub decode_csv_field {
    my ($raw) = @_;
    return '' unless defined $raw;

    if ($raw =~ /^"(.*)"\z/s) {
        my $value = $1;
        $value =~ s/""/"/g;
        return $value;
    }

    return $raw;
}

sub encode_replacement_like_original {
    my ($original_raw, $replacement) = @_;

    if ($original_raw =~ /^".*"\z/s) {
        my $escaped = $replacement;
        $escaped =~ s/"/""/g;
        return '"' . $escaped . '"';
    }

    return $replacement;
}

sub detect_line_ending {
    my ($line) = @_;
    return "\r\n" if $line =~ /\r\n\z/;
    return "\n"   if $line =~ /\n\z/;
    return '';
}

sub display_value {
    my ($value) = @_;
    return '<undefined>' unless defined $value;
    return '<empty>' unless length $value;
    return $value;
}

sub usage {
    my ($exit_code) = @_;

    print <<'USAGE';
Usage:
NumSplitter.pl [--backup] [--dry-run] <filename>

Options:
--backup   Create <filename>.bak before replacing the source file.
--dry-run  Validate and report changes without modifying the file.
--help     Show this help text.

Behavior:
- Reads a pipe-delimited header and locates the SBJ_ID field by name.
- Parses subsequent rows as CSV records.
- Splits only SBJ_ID values containing 20 or more digits.
- Uses balanced chunks of no more than 15 digits separated by one space.
- Leaves already-split valid SBJ_ID values unchanged.
- Leaves malformed records unchanged and reports them as warnings.
USAGE

    exit $exit_code;
}