import java.util.Scanner;
public class TestAverager {

	public static void main(String[] args) {
		try (Scanner Input = new Scanner(System.in)) {
		  int[] Grades = new int[6];
		  Grader(Grades, Input); 
		}
	}
		
	public static void Grader(int[] Grades, Scanner Input) {
		int Test;
		int Total = 0;
		double Avg = 0;
		int End = 999;
		int A = 0;
		System.out.print("Enter test grade or " + End + " to quit: ");
		Test = Input.nextInt();
		while(Test != End && A < Grades.length) {
		     Grades[A] = Test;
		     Total += Grades[A];
		     ++A;
		     if(A < Grades.length)
		     {
		        System.out.print("Enter next test grade or " + End + " to quit: ");
		        Test = Input.nextInt();  
		     }
		  }
		  if(A == 0)
		     System.out.println("Error: No grades were entered so average can't be calculated.");
		  else
		  {
		     Avg = Total / A;
		     System.out.println("You entered " + A + " grades." + "The test average is " + Avg);
		  }	      
	}
}
