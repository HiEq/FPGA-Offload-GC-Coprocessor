public class HelloWorld {
    public static void main(String[] args) {
        System.out.println("Hello from " + System.getProperty("java.vm.name") +
                           " " + System.getProperty("java.version"));
        System.out.println("java.home=" + System.getProperty("java.home"));
        System.out.println("os.arch=" + System.getProperty("os.arch"));
        Runtime rt = Runtime.getRuntime();
        long t0 = System.currentTimeMillis();
        System.gc();
        long t1 = System.currentTimeMillis();
        System.out.println("HELLO_GC_MS=" + (t1 - t0) +
                           " heap_kb=" + (rt.totalMemory() - rt.freeMemory()) / 1024);
    }
}
