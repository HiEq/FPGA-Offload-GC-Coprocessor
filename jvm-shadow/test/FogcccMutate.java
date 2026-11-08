// FogcccMutate - a graph that changes between collections, for the P3 card
// table and incremental export tests.
//
//   java FogcccMutate [N] [refs] [rounds] [mutations]
//
// Builds N nodes (refs each, node i -> i+1 kept as refs[0]), then for each
// round rewrites `mutations` reference fields and allocates N/20 fresh nodes
// (linked into a static chain), then calls System.gc().
public class FogcccMutate {
    static int N = 200000;
    static int REFS = 2;
    static int ROUNDS = 3;
    static int MUT = 20000;

    static class Node {
        int id;
        Node[] refs;
        Node(int id, int n) { this.id = id; this.refs = new Node[n]; }
    }

    static Node[] all;      // static so the graph stays live
    static Node[] root;
    static Node[] freshRoot;

    public static void main(String[] args) {
        if (args.length > 0) N = Integer.parseInt(args[0]);
        if (args.length > 1) REFS = Integer.parseInt(args[1]);
        if (args.length > 2) ROUNDS = Integer.parseInt(args[2]);
        if (args.length > 3) MUT = Integer.parseInt(args[3]);
        if (REFS < 1) REFS = 1;

        all = new Node[N];
        for (int i = 0; i < N; i++) all[i] = new Node(i, REFS);
        for (int i = 0; i < N; i++) {
            for (int j = 0; j < REFS; j++) all[i].refs[j] = all[(i + 1) % N];
            // keep the chain in refs[0]
            all[i].refs[0] = all[(i + 1) % N];
        }
        root = new Node[] { all[0] };
        freshRoot = new Node[] { null };

        long t0 = System.currentTimeMillis();
        for (int r = 0; r < ROUNDS; r++) {
            long m0 = System.currentTimeMillis();

            // Rewrite reference fields (dirty containers).
            for (int k = 0; k < MUT; k++) {
                int i = (int) (((long) k * 2654435761L + r * 97L) % N);
                int j = (int) (((long) i * 1103515245L + 12345L) % N);
                all[i].refs[REFS - 1] = all[j];
            }

            // Allocate fresh nodes and link them from a static root, so they
            // are reachable without rewriting the old graph.
            int fresh = N / 20;
            Node head = null;
            for (int k = 0; k < fresh; k++) {
                Node n = new Node(N + r * fresh + k, REFS);
                for (int j = 0; j < REFS; j++) n.refs[j] = all[(k * 7 + r) % N];
                n.refs[0] = (head != null) ? head : all[(k + r) % N];
                head = n;
            }
            freshRoot[0] = head;

            long m1 = System.currentTimeMillis();
            System.gc();
            long m2 = System.currentTimeMillis();

            System.out.println("MUTATE round=" + r +
                               " mutate_ms=" + (m1 - m0) +
                               " gc_ms=" + (m2 - m1));
        }
        System.out.println("MUTATE total_ms=" + (System.currentTimeMillis() - t0) +
                           " nodes=" + N + " refs=" + REFS +
                           " rounds=" + ROUNDS + " mutations=" + MUT);
    }
}
