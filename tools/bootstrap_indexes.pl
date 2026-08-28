#!/usr/bin/env perl
# Bootstrap script: builds LRR_SORTED_title and NSINDEX_* indexes for P1-A and P1-B.
# Run inside the LANraragi container after deploying the modified code:
#   docker exec -it lanraragi perl /app/tools/bootstrap_indexes.pl
#
# This script is idempotent — safe to run multiple times.
# It will:
#   1. Rebuild LRR_SORTED_title (precomputed natural-sorted title index)
#   2. Rebuild all NSINDEX_* sets (namespace secondary indexes for fuzzy tag search)

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Time::HiRes qw(time);
use LANraragi::Model::Config;
use LANraragi::Utils::Database qw(rebuild_title_sort_index);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Redis qw(redis_decode redis_encode);

my $logger = get_logger("Bootstrap", "lanraragi");

# ─── Phase 1: Rebuild LRR_SORTED_title ──────────────────────────────
print "=" x 60, "\n";
print "Phase 1: Rebuilding LRR_SORTED_title (title sort index)\n";
print "=" x 60, "\n";

my $t1 = time();
my $count = rebuild_title_sort_index();
printf("  Done: %d archives indexed in %.2fs\n\n", $count, time() - $t1);

# ─── Phase 2: Rebuild NSINDEX_* sets ────────────────────────────────
print "=" x 60, "\n";
print "Phase 2: Rebuilding NSINDEX_* (namespace secondary indexes)\n";
print "=" x 60, "\n";

my $t2 = time();
my $redis       = LANraragi::Model::Config->get_redis;
my $redis_search = LANraragi::Model::Config->get_redis_search;

# Get all archive IDs (40-char hex keys)
my @ids = $redis->keys('????????????????????????????????????????');
print "  Found " . scalar(@ids) . " archives to process\n";

# First, delete all existing NSINDEX_* keys
my @old_nskeys = $redis_search->keys('NSINDEX_*');
if (@old_nskeys) {
    $redis_search->del(@old_nskeys);
    print "  Cleared " . scalar(@old_nskeys) . " old NSINDEX_* keys\n";
}

# Scan all tags and build NSINDEX_* sets
my %ns_counts;
my $processed = 0;
my $batch_size = 1000;

# Use MULTI/EXEC for batch HGET
for (my $i = 0; $i < scalar @ids; $i += $batch_size) {
    my $end = $i + $batch_size - 1;
    $end = $#ids if $end > $#ids;
    my @batch = @ids[$i .. $end];

    $redis->multi;
    $redis->hget($_, "tags") for @batch;
    my @results = $redis->exec;

    for my $j (0 .. $#batch) {
        my $id   = $batch[$j];
        my $tags = $results[$j];
        next unless defined $tags;

        $tags = redis_decode($tags);
        my @tag_list = split(/,\s?/, $tags);

        foreach my $tag (@tag_list) {
            $tag = lc($tag);
            # Match namespace prefix: "namespace:value" -> NSINDEX_namespace:
            if ($tag =~ /^([^:]+):/) {
                my $ns = $1 . ":";
                # Redis module requires octet strings, not Perl's internal UTF-8 flag
                my $ns_key = redis_encode("NSINDEX_" . $ns);
                $redis_search->sadd($ns_key, $id);
                $ns_counts{$ns}++;
            }
        }
    }

    $processed += scalar(@batch);
    printf("  Processed %d / %d archives\n", $processed, scalar(@ids)) if $processed % 5000 == 0 || $processed == scalar(@ids);
}

printf("  Done: %d namespaces indexed in %.2fs\n", scalar(keys %ns_counts), time() - $t2);
print "  Top namespaces:\n";
foreach my $ns (sort { $ns_counts{$b} <=> $ns_counts{$a} } keys %ns_counts) {
    last if $ns_counts{$ns} < 100;  # Only show significant namespaces
    printf("    %-30s %d entries\n", $ns, $ns_counts{$ns});
}

$redis->quit;
$redis_search->quit;

print "\n";
print "=" x 60, "\n";
printf("Bootstrap complete! Total time: %.2fs\n", time() - $t1);
print "=" x 60, "\n";
