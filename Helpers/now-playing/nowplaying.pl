# Loads dock2's Now Playing reader into this platform binary, which macOS lets read what is playing.
# Usage: /usr/bin/perl nowplaying.pl /path/to/libdock2nowplaying.dylib
use strict; use warnings; use DynaLoader;
my $library = DynaLoader::dl_load_file($ARGV[0], 0) or die "dl_load_file: " . DynaLoader::dl_error() . "\n";
my $stream = DynaLoader::dl_find_symbol($library, "dock2_nowplaying_stream") or die "dl_find_symbol: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::stream", $stream);
stream();
