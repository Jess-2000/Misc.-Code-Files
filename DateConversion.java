import java.util.Date;
import java.util.Scanner;
import java.io.File;
import java.io.FileNotFoundException;
import java.text.SimpleDateFormat;

public class DateConversion {

   public static void main(String[] args) throws FileNotFoundException {
      String fileName = getString(args, "Enter file name: ");
      Scanner input = new Scanner(new File(fileName));
      String tradDate;   
      String normalDate; 

      while(input.hasNextLine()) {
         tradDate = input.nextLine();
         if(tradDate.length() > 0) {    
            normalDate = normalFormOf(tradDate);
            System.out.println(quoted(normalDate) + " : " + quoted(tradDate));
         }
      }
      System.out.println("Goodbye.");
   }
   
   public static String normalFormOf(String tradDate) {
	   SimpleDateFormat sdf = new SimpleDateFormat("yyyymmdd");
	   String result = sdf.format(new Date(tradDate));
	   return result;
   }
   public static String paddedWithZeros(String str, int desiredLen) {
      String result = "";
      return result;
   }
   private static String getString(String prompt, Scanner keyboard) {
      System.out.print(prompt);
      return keyboard.nextLine();
   }
   private static String getString(String[] args, String prompt) {
      String result;
      if (args.length > 0) {
         result = args[0];
      } else {
         Scanner keyboard = new Scanner(System.in);
         result = getString(prompt,keyboard).trim();
      }
      return result;
   }

   public static String quoted(String s) {
      final char QUOTE = '\"';
      return QUOTE + s + QUOTE;
   }
}

