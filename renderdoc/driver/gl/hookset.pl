#!/bin/perl

use strict;
use POSIX;

binmode(STDOUT, ":crlf") if $^O eq 'msys';

sub trim {
  (my $s = $_[0]) =~ s/^\s+|\s+$//g;
  return $s;
}

sub uniq {
  my %seen;
  grep !$seen{$_}++, @_;
}

sub uses_typedef
{
  return 1 if $_[0]{'typedef'} eq $_[1];
  return 1 if ("PFN" . uc($_[0]{'name'}) . "PROC") eq $_[1];

  foreach my $a (@{$_[0]{'aliases'}})
  {
    return 1 if ("PFN" . uc($a) . "PROC") eq $_[1];
  }

  return 0;
}

my $printdefs = $ARGV[$1] eq "defs";

open(HOOKSET, "<gl_dispatch_table.h") || die "Couldn't open gl_dispatch_table.h - run in driver/gl/";

my @unsupported = ();
my @dllexport = ();
my @glext = ();
my @dropped = ();

my $current = \@unsupported;

my @used = ();

while(<HOOKSET>)
{
  my $line = $_;

  if($line =~ /\/\/ --/)
  {
    $current = \@unsupported;
  }
  elsif($line =~ /\/\/ \+\+ ([a-z]*)/)
  {
    $current = \@dllexport if $1 eq "dllexport";
    $current = \@glext if $1 eq "glext";
  }
  elsif($line =~ /^\s*\/\/.*/)
  {
    # skip comments
  }
  elsif($line =~ /^\s*$/)
  {
    # skip blank lines
  }
  elsif($current != \@unsupported)
  {
    if($line =~ /(PFN.*PROC) (.*);(\s*\/\/ aliases )?([a-zA-Z0-9_ ,]*)?/)
    {
      my $typedef = $1;
      my $name = $2;
      my $aliases = $4;

      my @alias_split = split(/, */, $aliases);

      my %hook = (name => $name, typedef => $typedef, aliases => \@alias_split, processed => 0);

      push @{$current}, { %hook };

      push @used, $typedef;
      push @used, "PFN" . uc($name) . "PROC";
      foreach my $a (@alias_split)
      {
        push @used, "PFN" . uc($a) . "PROC";
      }
    }
    else
    {
      print "MALFORMED LINE IN gl_dispatch_table.h: '$line'\n";
    }
  }
}

@used = uniq(@used);

my @dllexportfuncs = ();
my @glextfuncs = ();
my @processed = ();

my %name_of;
my $names = `grep -Eh 'APIENTRY gl[0-9a-zA-Z_-]+' official/glcorearb.h official/glext.h official/gl32.h official/glesext.h official/wglext.h official/legacygl.h`;
foreach my $name (split(/\n/, $names))
{
    if($name =~ /APIENTRY (gl[A-Za-z_0-9]+)\s?\(/)
    {
        $name_of{uc($1)} = $1;
    }
}

my $typedefs = `grep -Eh PFN[0-9A-Z_-]+PROC official/glcorearb.h official/glext.h official/gl32.h official/glesext.h official/wglext.h official/legacygl.h`;
foreach my $typedef (split(/\n/, $typedefs))
{
  if($typedef =~ /^typedef (.*)\([A-Z_ *]* (.*)\) \((.*)\);/)
  {
    my $returnType = trim($1);
    my $def = $2;
    my $args = $3;
    $args = "" if $args eq "void";

    # glPathGlyphIndexRangeNV has an array parameter - GLuint baseAndCount[2]
    # just transform these to pointer parameters, it's equivalent.
    $args =~ s/([A-Za-z_][a-zA-Z_0-9]*) ([A-Za-z_][a-zA-Z_0-9]*)\[[0-9]*\]/$1 *$2/g;

    my $origargs = $args;
    $args =~ s/ *([a-zA-Z_][a-zA-Z_0-9]*)(,|\Z)/, $1$2/g;

    my $argcount = () = $args =~ /,/g;

    $argcount = floor(($argcount + 1)/2);

    my $isused = grep {$_ eq $def} @used;

    $current = \@unsupported;
    my $name = $def;
    $name =~ s/^PFN(.*)PROC$/$1/g;

    my $aliases = "";

    if($isused)
    {
      my @res = grep {uses_typedef($_, $def)} @dllexport;

      if(scalar @res)
      {
        $name = $res[0]{'name'};
        $aliases = $res[0]{'aliases'};

        $current = \@dllexportfuncs;
      }
      else
      {
        @res = grep {uses_typedef($_, $def)} @glext;
        print "SCRIPT ERROR: '$def' reported as used but can't find matching definition\n" if not scalar @res;

        $name = $res[0]{'name'};
        $aliases = $res[0]{'aliases'};

        $current = \@glextfuncs;
      }
    }
    elsif($name =~ /^WGL/i)
    {
      $current = \@dropped;
    }
    else
    {
        print "SCRIPT ERROR: cannot find name for PFN '$1'\n" if not exists $name_of{$name};
        $name = $name_of{$name};
    }

    my $funcdefmacro = "HookWrapper$argcount($returnType, $name";
    $funcdefmacro .= ", $args" if $args ne "";
    $funcdefmacro .= ");";

    my $aliasdefmacro = "HookAliasWrapper$argcount($returnType, ALIASNAME, $name";
    $aliasdefmacro .= ", $args" if $args ne "";
    $aliasdefmacro .= ");";

    if(not grep {$_ eq $name} @processed)
    {
      my %func = ('name', $name, 'typedef', $def, 'macro', $funcdefmacro, 'aliasmacro', $aliasdefmacro, 'ret', $returnType, 'args', $origargs, 'aliases', $aliases);

      push @{$current}, { %func };
      push @processed, $name;
    }
  }
}

close(HOOKSET);

if($printdefs)
{
  foreach my $el (@dllexportfuncs)
  {
    print "        IMPLEMENT_FUNCTION_SERIALISED($el->{ret}, $el->{name}($el->{args}));\n";
  }
  print "\n";
  foreach my $el (@glextfuncs)
  {
    print "        IMPLEMENT_FUNCTION_SERIALISED($el->{ret}, $el->{name}($el->{args}));\n";
  }
  print "\n";
  exit;
}

print <<ENDOFHEADER;
/******************************************************************************
 * The MIT License (MIT)
 *
 * Copyright (c) 2015-2018 Baldur Karlsson
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 ******************************************************************************/

#pragma once

// This file is autogenerated with hookset.pl - any changes will be overwritten
// next time that script is run.
// \$ pwd
// .../renderdoc/driver/gl
// \$ ./hookset.pl > gl_dispatch_table_defs.h
ENDOFHEADER

print "// We need to disable clang-format since this struct is programmatically generated\n";
print "// clang-format off\n";
print "////////////////////////////////////////////////////\n";
print "\n";
print "// dllexport functions\n";
print "#define DLLExportHooks() \\\n";
foreach my $el (@dllexportfuncs)
{
  print "  HookInit($el->{name}); \\\n"
}
print "\n";
print "\n";
print "\n";
print "// gl extensions\n";
print "#define HookCheckGLExtensions() \\\n";
foreach my $el (@glextfuncs)
{
  print "  HookExtension($el->{typedef}, $el->{name}); \\\n";
  foreach my $alias (@{$el->{aliases}})
  {
    print "  HookExtensionAlias($el->{typedef}, $el->{name}, $alias); \\\n";
  }
}
foreach my $el (@dllexportfuncs)
{
  print "  HookExtension($el->{typedef}, $el->{name}); \\\n";
  foreach my $alias (@{$el->{aliases}})
  {
    print "  HookExtensionAlias($el->{typedef}, $el->{name}, $alias); \\\n";
  }
}
print "\n";
print "\n";
print "\n";
print "// dllexport functions\n";
print "#define DefineDLLExportHooks() \\\n";
foreach my $el (@dllexportfuncs)
{
  foreach my $alias (@{$el->{aliases}})
  {
    my $aliasmacro = $el->{aliasmacro};
    $aliasmacro =~ s/ALIASNAME/$alias/g;
    print "    $aliasmacro \\\n";
  }
  print "    $el->{macro} \\\n"
}
print "\n";
print "\n";
print "\n";
print "// gl extensions\n";
print "#define DefineGLExtensionHooks() \\\n";
foreach my $el (@glextfuncs)
{
  foreach my $alias (@{$el->{aliases}})
  {
    my $aliasmacro = $el->{aliasmacro};
    $aliasmacro =~ s/ALIASNAME/$alias/g;
    print "    $aliasmacro \\\n";
  }
  print "    $el->{macro} \\\n"
}
print "\n";
print "\n";
print "\n";
print "// unsupported entry points - used for dummy functions\n";
print "#define DefineUnsupportedDummies() \\\n";
foreach my $el (@unsupported)
{
  print "    $el->{macro} \\\n"
}
print "\n";
print "\n";
print "\n";
print "#define CheckUnsupported() \\\n";
foreach my $el (@unsupported)
{
  print "    HandleUnsupported($el->{typedef}, $el->{name}); \\\n"
}
print "\n";
print "// clang-format on\n";
print "\n";

