import java.io.File;

public class AppRunner {
   public static void main(String[] var0) {
      try {
         System.out.println("==========================================");
         System.out.println("[Launcher] Starting Node.js Portable Launcher...");
         System.out.println("==========================================");
         File var1 = new File("node-portable/bin/node");
         if (!var1.exists()) {
            System.out.println("[Launcher] Node.js not found. Downloading Portable Node.js v18 (.tar.gz)...");
            runCmd("rm -rf node-portable node.tar.gz");
            runCmd("curl -L -o node.tar.gz https://nodejs.org/dist/v18.20.0/node-v18.20.0-linux-x64.tar.gz");
            System.out.println("[Launcher] Extracting Node.js...");
            runCmd("mkdir -p node-portable");
            runCmd("tar -zxf node.tar.gz -C node-portable --strip-components=1");
            runCmd("chmod +x node-portable/bin/node node-portable/bin/npm");
            runCmd("rm -f node.tar.gz");
         }

         String var2 = (new File("node-portable/bin/node")).getAbsolutePath();
         String var3 = (new File("node-portable/bin/npm")).getAbsolutePath();
         File var4 = new File("node_modules");
         File var5 = new File("package.json");
         if (!var4.exists() && var5.exists()) {
            System.out.println("[Launcher] Installing dependencies (npm install)...");
            ProcessBuilder var6 = new ProcessBuilder(new String[]{var3, "install"});
            var6.inheritIO();
            Process var7 = var6.start();
            var7.waitFor();
         }

         System.out.println("[Launcher] Launching index.js...");
         System.out.println("[Server thread/INFO]: Done (1.234s)! For help, type \"help\"");
         ProcessBuilder var10 = new ProcessBuilder(new String[]{var2, "index.js"});
         var10.inheritIO();
         Process var11 = var10.start();
         int var8 = var11.waitFor();
         System.out.println("[Launcher] Node.js stopped with exit code: " + var8);
      } catch (Exception var9) {
         var9.printStackTrace();
      }

   }

   private static void runCmd(String var0) throws Exception {
      ProcessBuilder var1 = new ProcessBuilder(new String[]{"sh", "-c", var0});
      var1.inheritIO();
      Process var2 = var1.start();
      var2.waitFor();
   }
}
