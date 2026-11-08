// FogcccThreads - concurrent mutators plus GC, for the dirty-barrier race.
//
// The chain is reachable from the static root array.  Each node's refs[1]
// holds a payload that is reachable ONLY through that field: a lost barrier
// record leaves the node's side-table entry stale, so the new payload is not
// part of the hardware closure and can be swept while still referenced.
//
//   java FogcccThreads [threads] [iterations]
public class FogcccThreads {
    static final int N = 4000;
    static Node[] root;
    static Node[] chain;

    static class Node {
        int tag;
        Node[] refs;
        Node(int t) { tag = t; refs = new Node[2]; }
    }

    public static void main(String[] args) throws Exception {
        final int T = args.length > 0 ? Integer.parseInt(args[0]) : 4;
        final int ITER = args.length > 1 ? Integer.parseInt(args[1]) : 4000;

        chain = new Node[N];
        for (int i = 0; i < N; i++) chain[i] = new Node(i);
        for (int i = 0; i < N; i++) {
            chain[i].refs[0] = chain[(i + 1) % N];
            chain[i].refs[1] = new Node(1000000 + i);
        }
        root = new Node[] { chain[0] };

        Thread[] ts = new Thread[T];
        for (int t = 0; t < T; t++) {
            final int tt = t;
            ts[t] = new Thread(new Runnable() {
                public void run() {
                    for (int k = 0; k < ITER; k++) {
                        int i = (tt * 977 + k * 31) % N;
                        chain[i].refs[1] = new Node(2000000 + tt * 1000000 + k);
                    }
                }
            });
            ts[t].start();
        }

        for (int g = 0; g < 20; g++) {
            System.gc();
            Thread.sleep(5);
        }
        for (int t = 0; t < T; t++) ts[t].join();

        int bad = 0, nulls = 0;
        for (int i = 0; i < N; i++) {
            if (chain[i].refs[0] != chain[(i + 1) % N]) bad++;
            Node p = chain[i].refs[1];
            if (p == null || p.refs == null) nulls++;
        }
        System.out.println("THREADS bad=" + bad + " nulls=" + nulls +
                           " T=" + T + " iter=" + ITER);
    }
}
