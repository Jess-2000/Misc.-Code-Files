public class ArrayMethod {
	
	public static void Main(String[] args)
	   {
	      int[] Numbers = {10, 5, 50, 100, 45, 7, 800, 150};
	      int Max = 450;
	      display(Numbers);
	      Reverse(Numbers);
	      Sum(Numbers);
	      LessThan(Numbers, Max);
	      GreaterThanAverage(Numbers);
	   }
	   public static void display(int[] Numbers)
	   {
	      System.out.print("Your lucky numbers are:  ");
	      for(int i = 0; i < Numbers.length; ++ i)
	         System.out.print(Numbers[i] + "  ");
	   }
	   public static void Reverse(int[] Numbers)
	   {
	      System.out.print("\nThe backwards order of your numbers is:  ");
	      for(int i = Numbers.length - 1; i >= 0; -- i)
	         System.out.print(Numbers[i] + "  ");
	   }
	   public static void Sum(int[] Numbers)
	   {
	      int Total = 0;
	      for(int i = 0; i < Numbers.length; i++)
	      {
	         Total += Numbers[i];
	      }
	      System.out.println("\nThe sum of your numbers is " + Total);
	   }
	   public static void LessThan(int[] Numbers, int Max)
	   {
	       for(int i = 0; i < Numbers.length; i++)
	         if(Numbers[i] < Max)
	             System.out.print(Numbers[i] + " ");
	        System.out.println("are less than the maximum number " + Max);

	   }
	   public static void GreaterThanAverage(int[] Numbers)
	   {
	      int Sum = 0;
	      double Avg;
	      for(int i = 0; i < Numbers.length; ++i)
	         Sum += Numbers[i];
	      Avg = Sum * 1.0 / Numbers.length;
	      System.out.println("The average of your numbers is " + Avg);
	      for(int i = 0; i < Numbers.length; i++)
	         if(Numbers[i] > Avg)
		    System.out.print(Numbers[i] + "  ");
	      System.out.println("are greater than the average");
	   }
}

