// 4K-object workload for the JamVM shadow test.
// One static root reaches every node through a chain; random refs add graph shape.
//   java FogcccWorkload [N] [avg_refs]
import java.util.Random;

public class FogcccWorkload {
    static int N = 4000;
    static int AVG_REFS = 2;
    static int CHAIN = 0;
    static Node[] root;

    static class Node {
        int id;
        Node[] refs;
        Node(int id, int n) {
            this.id = id;
            this.refs = new Node[n];
        }
    }

    static Node[] build() {
        Random r = new Random(42);
        Node[] all = new Node[N];
        for (int i = 0; i < N; i++) all[i] = new Node(i, AVG_REFS);
        for (int i = 0; i < N; i++) {
            for (int j = 0; j < AVG_REFS; j++) {
                all[i].refs[j] = all[r.nextInt(N)];
            }
        }
        // Keep every node reachable from the single static root: refs[0] is
        // always the chain successor; refs[1..] follow it for CHAIN% of the
        // nodes (narrow frontier) and stay random otherwise (wide frontier).
        for (int i = 0; i + 1 < N; i++) {
            all[i].refs[0] = all[i + 1];
            for (int j = 1; j < AVG_REFS; j++) {
                if (r.nextInt(100) < CHAIN) all[i].refs[j] = all[i + 1];
            }
        }
        root = new Node[1];
        root[0] = all[0];
        return all;
    }

    public static void main(String[] args) {
        if (args.length > 0) N = Integer.parseInt(args[0]);
        if (args.length > 1) AVG_REFS = Integer.parseInt(args[1]);
        if (args.length > 2) CHAIN = Integer.parseInt(args[2]);
        if (AVG_REFS < 1) AVG_REFS = 1;
        if (CHAIN < 0) CHAIN = 0;
        if (CHAIN > 100) CHAIN = 100;

        Node[] all = build();
        int lastId = all[N - 1].id;
        all = null; // only the static root keeps the graph alive

        Runtime rt = Runtime.getRuntime();
        long t0 = System.currentTimeMillis();
        for (int i = 0; i < 3; i++) {
            long g0 = System.currentTimeMillis();
            System.gc();
            long g1 = System.currentTimeMillis();
            System.out.println("FOGCCC_GC round=" + i + " gc_ms=" + (g1 - g0));
        }
        long t1 = System.currentTimeMillis();

        System.out.println("FOGCCC_WORKLOAD vm=" + System.getProperty("java.vm.name") +
                           " nodes=" + N +
                           " refs=" + AVG_REFS +
                           " chain=" + CHAIN +
                           " gc_ms=" + (t1 - t0) +
                           " heap_used_kb=" + (rt.totalMemory() - rt.freeMemory()) / 1024 +
                           " root=" + root[0].id +
                           " last=" + lastId);
    }
}
