// Complete binary tree workload: node i -> 2i+1, 2i+2.
// Rooted at a 1-element array.  BFS frontier at the last level is ~N/2 while
// a DFS mark stack only holds ~log2(N) entries -- the tree is the case where
// a DFS-depth proxy and the hardware queue width diverge.
//   java FogcccTree [N]
public class FogcccTree {
    static int N = 200000;
    static Node[] root;

    static class Node {
        int id;
        Node[] kids;   // 2
        Node(int id) { this.id = id; this.kids = new Node[2]; }
    }

    public static void main(String[] args) {
        if (args.length > 0) N = Integer.parseInt(args[0]);

        Node[] all = new Node[N];
        for (int i = 0; i < N; i++) all[i] = new Node(i);
        for (int i = 0; i < N; i++) {
            if (2 * i + 1 < N) all[i].kids[0] = all[2 * i + 1];
            if (2 * i + 2 < N) all[i].kids[1] = all[2 * i + 2];
        }
        root = new Node[] { all[0] };
        all = null;

        long t0 = System.currentTimeMillis();
        for (int i = 0; i < 3; i++) {
            long g0 = System.currentTimeMillis();
            System.gc();
            long g1 = System.currentTimeMillis();
            System.out.println("FOGCCC_TREE round=" + i + " gc_ms=" + (g1 - g0));
        }
        System.out.println("FOGCCC_TREE nodes=" + N +
                           " total_ms=" + (System.currentTimeMillis() - t0));
    }
}
