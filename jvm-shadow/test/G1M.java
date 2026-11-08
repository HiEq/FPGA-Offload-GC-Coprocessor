public class G1M {
    static Object[] root = new Object[1];

    static class N {
        int id;
        N next;
        N other;
    }

    public static void main(String[] a) {
        int n = a.length > 0 ? Integer.parseInt(a[0]) : 1000000;
        N[] all = new N[n];
        for (int i = 0; i < n; i++)
            all[i] = new N();
        for (int i = 0; i < n; i++) {
            all[i].id = i;
            if (i + 1 < n)
                all[i].next = all[i + 1];
            all[i].other = all[(i * 37 + 11) % n];
        }
        root[0] = all[0];
        all = null;
        long t0 = System.currentTimeMillis();
        for (int k = 0; k < 3; k++) {
            long g0 = System.currentTimeMillis();
            System.gc();
            long g1 = System.currentTimeMillis();
            System.out.println("FOGCCC_GC round=" + k + " gc_ms=" + (g1 - g0));
        }
        System.out.println("G1M_DONE nodes=" + n + " root=" + ((N) root[0]).id
                + " ms=" + (System.currentTimeMillis() - t0));
    }
}
