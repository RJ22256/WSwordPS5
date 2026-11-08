// Savage Wind: read-only queries against an analyzed Ghidra program, driven by tools/ghidra/gq.py.
//
// The only script argument is a request file: line 1 is the output path, line 2 the command, every
// further line one argument (a file instead of command-line arguments keeps regexes and C++ names
// intact through analyzeHeadless.bat on Windows). Nothing in the program is modified.
//@category SavageWind

import java.io.FileOutputStream;
import java.io.OutputStreamWriter;
import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Pattern;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;

public class SWQuery extends GhidraScript {
    private static final int MAX_REFS = 500;
    private PrintWriter out;
    private DecompInterface decomp;

    @Override
    public void run() throws Exception {
        List<String> req = Files.readAllLines(Paths.get(getScriptArgs()[0]), StandardCharsets.UTF_8);
        out = new PrintWriter(new OutputStreamWriter(new FileOutputStream(req.get(0)), StandardCharsets.UTF_8));
        try {
            String cmd = req.get(1);
            List<String> args = req.subList(2, req.size());
            switch (cmd) {
                case "decompile": for (String s : args) decompile(s); break;
                case "xrefs": for (String s : args) xrefs(s); break;
                case "callees": for (String s : args) callees(s); break;
                case "disasm": disasm(args.get(0), args.size() > 1 ? Integer.parseInt(args.get(1)) : 40); break;
                case "data": data(args.get(0), args.size() > 1 ? Integer.parseInt(args.get(1)) : 4); break;
                case "strings": strings(args.get(0), args.size() > 1 ? Integer.parseInt(args.get(1)) : 100); break;
                case "symbols": symbols(args.get(0), args.size() > 1 ? Integer.parseInt(args.get(1)) : 100); break;
                case "functions": functions(); break;
                case "summary": summary(); break;
                default: out.println("unknown command: " + cmd);
            }
        } finally {
            if (decomp != null) {
                decomp.dispose();
            }
            out.close();
        }
    }

    /** An address ("0x7100123450") or a symbol name; null (with a message) when it resolves to nothing. */
    private Address resolve(String s) {
        if (s.matches("(?i)(0x)?[0-9a-f]+")) {
            return toAddr(s.toLowerCase().startsWith("0x") ? s.substring(2) : s);
        }
        // A qualified name ("nn::fs::MountRom") is looked up by its last part, then matched in full; the
        // leading namespaces Ghidra adds (such as <EXTERNAL>::) may be left out.
        String last = s.contains("::") ? s.substring(s.lastIndexOf("::") + 2) : s;
        SymbolIterator it = currentProgram.getSymbolTable().getSymbols(last);
        while (it.hasNext()) {
            Symbol sym = it.next();
            String full = sym.getName(true);
            if (full.equals(s) || full.endsWith("::" + s) || !s.contains("::")) {
                return sym.getAddress();
            }
        }
        out.println("?? no symbol named " + s);
        return null;
    }

    private Function functionAt(String s) {
        Address a = resolve(s);
        if (a == null) {
            return null;
        }
        Function f = getFunctionContaining(a);
        if (f == null) {
            out.println("?? no function contains " + a);
        }
        return f;
    }

    private String where(Address a) {
        Function f = getFunctionContaining(a);
        return f == null ? "(no function)" : f.getName(true) + "+0x" + Long.toHexString(a.subtract(f.getEntryPoint()));
    }

    private void header(Function f) {
        out.printf("== %s @ %s  (%d bytes, %d callers, %d callees)%n", f.getName(true), f.getEntryPoint(),
                f.getBody().getNumAddresses(), f.getCallingFunctions(monitor).size(), f.getCalledFunctions(monitor).size());
    }

    private void decompile(String s) throws Exception {
        Function f = functionAt(s);
        if (f == null) {
            return;
        }
        if (decomp == null) {
            decomp = new DecompInterface();
            decomp.openProgram(currentProgram);
        }
        header(f);
        DecompileResults r = decomp.decompileFunction(f, 180, monitor);
        if (r.decompileCompleted()) {
            out.println(r.getDecompiledFunction().getC());
        } else {
            out.println("?? decompilation failed: " + r.getErrorMessage());
        }
    }

    private void xrefs(String s) {
        Address a = resolve(s);
        if (a == null) {
            return;
        }
        Function f = getFunctionAt(a);
        out.printf("== references to %s%s%n", a, f != null ? " (" + f.getName(true) + ")" : "");
        int n = 0;
        for (Reference r : getReferencesTo(a)) {
            if (n++ >= MAX_REFS) {
                out.println("   ... (more than " + MAX_REFS + ")");
                break;
            }
            out.printf("   %s  %-16s %s%n", r.getFromAddress(), r.getReferenceType(), where(r.getFromAddress()));
        }
    }

    private void callees(String s) {
        Function f = functionAt(s);
        if (f == null) {
            return;
        }
        header(f);
        Set<String> lines = new TreeSet<>();
        for (Function c : f.getCalledFunctions(monitor)) {
            lines.add(String.format("   %s  %s", c.getEntryPoint(), c.getName(true)));
        }
        lines.forEach(out::println);
    }

    private void disasm(String s, int count) {
        Address a = resolve(s);
        if (a == null) {
            return;
        }
        Listing listing = currentProgram.getListing();
        Instruction ins = listing.getInstructionContaining(a);
        if (ins == null) {
            ins = listing.getInstructionAfter(a);
        }
        out.println("== " + where(a));
        for (int i = 0; i < count && ins != null; i++, ins = ins.getNext()) {
            out.printf("   %s  %s%n", ins.getAddress(), ins);
        }
    }

    /** count 64-bit words from an address, each with the symbol or function it points to (pointers, GOT slots). */
    private void data(String s, int count) throws Exception {
        Address a = resolve(s);
        if (a == null) {
            return;
        }
        for (int i = 0; i < count; i++, a = a.add(8)) {
            long v = getLong(a);
            Address target = toAddr(v);
            Symbol sym = getSymbolAt(a);
            String to = "";
            if (currentProgram.getMemory().contains(target)) {
                Symbol ts = getSymbolAt(target);
                to = " -> " + (ts != null ? ts.getName(true) : where(target));
            }
            out.printf("%s  %016x%s%s%n", a, v, sym != null ? "  [" + sym.getName(true) + "]" : "", to);
        }
    }

    private void strings(String regex, int max) {
        Pattern p = Pattern.compile(regex);
        DataIterator it = currentProgram.getListing().getDefinedData(true);
        int n = 0;
        while (it.hasNext() && n < max && !monitor.isCancelled()) {
            Data d = it.next();
            if (!d.hasStringValue()) {
                continue;
            }
            String v = String.valueOf(d.getValue());
            if (!p.matcher(v).find()) {
                continue;
            }
            n++;
            List<String> users = new ArrayList<>();
            for (Reference r : getReferencesTo(d.getAddress())) {
                if (users.size() >= 5) {
                    users.add("...");
                    break;
                }
                users.add(where(r.getFromAddress()));
            }
            out.printf("%s  \"%s\"  <- %s%n", d.getAddress(), v.replace("\n", "\\n"), users.isEmpty() ? "(no references)" : String.join(", ", users));
        }
    }

    private void symbols(String regex, int max) {
        Pattern p = Pattern.compile(regex);
        SymbolIterator it = currentProgram.getSymbolTable().getAllSymbols(true);
        int n = 0;
        while (it.hasNext() && n < max && !monitor.isCancelled()) {
            Symbol sym = it.next();
            String name = sym.getName(true);
            if (p.matcher(name).find()) {
                n++;
                out.printf("%s  %-10s %s%n", sym.getAddress(), sym.getSymbolType(), name);
            }
        }
    }

    private void functions() {
        out.println("entry\tname\tbytes\treferences\tthunk");
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            out.printf("%s\t%s\t%d\t%d\t%s%n", f.getEntryPoint(), f.getName(true), f.getBody().getNumAddresses(),
                    currentProgram.getReferenceManager().getReferenceCountTo(f.getEntryPoint()), f.isThunk());
        }
    }

    private void summary() {
        out.println("program   " + currentProgram.getName());
        out.println("language  " + currentProgram.getLanguageID() + " / " + currentProgram.getCompilerSpec().getCompilerSpecID());
        out.println("base      " + currentProgram.getImageBase());
        out.println("functions " + currentProgram.getFunctionManager().getFunctionCount());
        out.println("symbols   " + currentProgram.getSymbolTable().getNumSymbols());
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            out.printf("block     %-12s %s-%s %s%n", b.getName(), b.getStart(), b.getEnd(),
                    (b.isRead() ? "r" : "-") + (b.isWrite() ? "w" : "-") + (b.isExecute() ? "x" : "-"));
        }
    }
}
