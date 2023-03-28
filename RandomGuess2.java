import javax.swing.JOptionPane;
public class RandomGuess2
{
   public static void main(String[] args)
   {
      int guess;
      int result;
      String msg;
      final int LOW = 1;
      final int HIGH = 10;
      result = LOW + (int)(Math.random() * HIGH);
      guess = Integer.parseInt(JOptionPane.showInputDialog(null,
         "Try to guess my number between " + LOW + " and " + HIGH));
      if(guess == result)
         msg = "Correct!";
      else
         if(guess < result)
            msg = "Your guess was too low";
         else
            msg = "Your guess was too high";
      
      JOptionPane.showMessageDialog(null,"The number is " + result + msg);
   }
}
