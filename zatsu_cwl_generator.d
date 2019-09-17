#!/usr/bin/env rdmd
import std;

@safe:

immutable IntRegex= ctRegex!r"^\d+$";
immutable DoubleRegex = ctRegex!r"^\d+\.\d+$";

version(unittest) {}
else
void main(string[] args)
{
    if (args.length != 2)
    {
        writefln("Usage: %s <commandline>", args[0]);
        return;
    }
    args[1].toCWL.write;
}

/**
 * Returns: a CWL definition from a given commandline `cmd`.
 */
auto toCWL(string cmd)
{
    auto sout = "";
    auto serr = "";

    // detect redirect to stderr
    if (auto arr = cmd.findSplit("2>"))
    {
        auto pre = arr[0].stripRight;
        assert(arr[1] == "2>");
        auto post = arr[2].stripLeft;

        auto tmp = post.split;
        enforce(!tmp.empty, "No file specified to be redirected stderr!");
        if (tmp.length == 1)
        {
            serr = tmp[0];
            cmd = pre;
        }
        else
        {
            serr = tmp[1];
            cmd = pre ~ " " ~ tmp[2..$].join(" ");
        }
    }

    // detect redirect to stdout
    if (auto arr = cmd.findSplit(">"))
    {
        auto pre = arr[0].stripRight;
        assert(arr[1] == ">");
        auto post = arr[2].stripLeft;

        enforce(post.split.length == 1, "One file should be allowed after `>`!");
        sout = post;
        cmd = pre;
    }

    immutable class_ = "CommandLineTool";
    immutable cwlVersion = "v1.0";
    immutable stdout_ = sout.empty ? "" : sout;
    immutable stderr_ = serr.empty ? "" : serr;

    auto args = cmd.split;
    enforce(!args.empty);

    immutable baseCommand = args[0];

    auto cwl = format(q"EOS
class: %s
cwlVersion: %s
baseCommand: %s
EOS", class_, cwlVersion, baseCommand);

    string[] arguments, inputs;
    string prevOption;
    foreach(i, a; args[1..$])
    {
        if (a.startsWith("-"))
        {
            arguments ~= format("  - %s", a);
            prevOption = a;
        }
        else
        {
            // guess type from option name
            immutable type = a.guessType(prevOption);
            immutable param = (prevOption.empty ? a : prevOption).toInputParam;
            arguments ~= format("  - $(inputs.%s)", param);
            inputs ~= format(q"EOS
  - id: %s
    type: %s
EOS", param, type);
            prevOption = "";
        }
    }
    cwl ~= "arguments:" ~ (arguments.empty ? " []" : "\n"~arguments.join("\n")) ~ "\n";
    cwl ~= "inputs:" ~ (inputs.empty ? " []\n" : "\n"~inputs.join);

    string[] outputs;
    if (!stdout_.empty)
    {
        outputs ~= q"EOS
  - id: out
    type: stdout
EOS";
    }
    if (!stderr_.empty)
    {
        outputs ~= q"EOS
  - id: err
    type: stderr
EOS";
    }
    cwl ~= "outputs:" ~ (outputs.empty ? " []\n" : "\n"~outputs.join);

    if (!stdout_.empty)
    {
        cwl ~= format("stdout: %s\n", stdout_);
    }
    if (!stderr_.empty)
    {
        cwl ~= format("stderr: %s\n", stderr_);
    }
    return cwl;
}

/// Simple example
unittest
{
    assert("cat aaa.txt bbb.txt > output.txt".toCWL ==
        q"EOS
class: CommandLineTool
cwlVersion: v1.0
baseCommand: cat
arguments:
  - $(inputs.aaa_txt)
  - $(inputs.bbb_txt)
inputs:
  - id: aaa_txt
    type: File
  - id: bbb_txt
    type: File
outputs:
  - id: out
    type: stdout
stdout: output.txt
EOS");
}

/// with options
unittest
{
    assert("head -n 5 ccc.txt > output.txt".toCWL ==
        q"EOS
class: CommandLineTool
cwlVersion: v1.0
baseCommand: head
arguments:
  - -n
  - $(inputs.n)
  - $(inputs.ccc_txt)
inputs:
  - id: n
    type: int
  - id: ccc_txt
    type: File
outputs:
  - id: out
    type: stdout
stdout: output.txt
EOS");
}

/**
 * Returns: a valid CWL input parameter id generated from `value`
 */
auto toInputParam(string value)
in(!value.empty)
do
{
    if (value.startsWith("-"))
    {
        value = value.stripLeft("-");
    }

    if (value.matchFirst(IntRegex))
    {
        return "_" ~ value;
    }
    else if (value.matchFirst(DoubleRegex))
    {
        return "_" ~ value.tr(".", "_");
    }
    else
    {
        return value.baseName.tr(".-", "_");
    }
}

///
unittest
{
    assert("5".toInputParam == "_5");
    assert("3.14".toInputParam == "_3_14");
    assert("foobar.txt".toInputParam == "foobar_txt");
    assert("value".toInputParam == "value");

    // For #5
    assert("this-file-is.txt".toInputParam == "this_file_is_txt");

    assert("-n".toInputParam == "n");
    assert("--option".toInputParam == "option");

    assert("../relative/path/to/file.txt".toInputParam == "file_txt");
    assert("/abspath/to/dir".toInputParam == "dir");
}

/**
 * Returns: a type string reasoned from the option and its value
 */
auto guessType(string value, string option = "")
{
    if (option.endsWith("dir"))
    {
        return "Directory";
    }
    else if (option.endsWith("file"))
    {
        return "File";
    }

    if (value.match(IntRegex))
    {
        return "int";
    }
    else if (value.match(DoubleRegex))
    {
        return "double";
    }
    else if (value.canFind(dirSeparator))
    {
        // It will be an absolute path or a relative path
        return value.baseName.canFind(".") ? "File" : "Directory";
    }
    else if (value.canFind("."))
    {
        // It will be a file in current directory
        return "File";
    }
    return "Any";
}

///
unittest
{
    /* guess a type from the option if it is provided */
    // if option ends with `dir`, it will be a directory
    assert("foo".guessType("--outdir") == "Directory");
    // if option ends with `file`, it will be a File
    assert("bar".guessType("--outfile") == "File");

    /* otherwise guess a typpe from its value */
    // if the value seems to be an integer, it will be an integer
    assert("13".guessType == "int");
    // if the value seems to be a floating ppoint, it will be a double precision number
    assert("13.5".guessType == "double");
    // if the value seems to be a file with an extension, it will be a File
    assert("foobar.txt".guessType == "File");
    assert("../hoge.txt".guessType == "File");
    // if it seems to be a path but no extensions, it will be a directory
    assert("/path/to/dir".guessType == "Directory");

    // return `Any` if it cannot guess a type
    assert("13a".guessType == "Any");
    assert("unknown-value".guessType("--unknown-option") == "Any");
}
