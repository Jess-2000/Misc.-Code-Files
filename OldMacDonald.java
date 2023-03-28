public class OldMacDonald {

	public static void main(String[] args) {
		Title();
		
		Space();
		
		Snake();
		
		Lion();
		
		Bear(); 
		 
		Owl();
		
		SnakeR();
		
		LionR();
		
		BearR();
	}
	
	public static void Title() {
		 System.out.println("Old MacDonald had a zoo, E-I-E-I-O");
	}
	
	public static void Space() {
		 System.out.println();
	}
	
	public static void SnakeR() {
		System.out.println("With a hiss-hiss here and a hiss-hiss there");
	    System.out.println("Here a hiss, there a hiss, everywhere a hiss-hiss");
	}
	
	public static void LionR() {
		System.out.println("With a roar-roar here and a roar-roar there");
		System.out.println("Here a roar, there a roar, everywhere a roar-roar");
	}
	
	public static void BearR() {
		System.out.println("With a growl-growl here and a growl-growl there");
		System.out.println("Here a growl, there a growl, everywhere a growl-growl");
	}
	
	public static void Snake() {
		System.out.println("And in this zoo he had a snake, E-I-E-I-O");
		System.out.println("With a hiss-hiss here and a hiss-hiss there");
	    System.out.println("Here a hiss, there a hiss, everywhere a hiss-hiss");
	    Title();
	    Space();
	}
	
	public static void Lion() {
		Title();
		System.out.println("And in this zoo he had a lion, E-I-E-I-O");
		System.out.println("With a roar-roar here and a roar-roar there");
		System.out.println("Here a roar, there a roar, everywhere a roar-roar");
		SnakeR();
		Title();
		Space();
	}
	
	public static void Bear() {
		Title();
		System.out.println("And in this zoo he had a bear, E-I-E-I-O");
		System.out.println("With a growl-growl here and a growl-growl there");
		System.out.println("Here a growl, there a growl, everywhere a growl-growl");
		LionR();
		SnakeR();
		Title();
		Space();
	}
	
	public static void Owl() {
		Title();
		System.out.println("And in this zoo he had an owl, E-I-E-I-O");
		System.out.println("With a hoot-hoot here and a hoot-hoot there");
		System.out.println("Here a hoot, there a hoot, everywhere a hoot-hoot");
		BearR();
		LionR();
		SnakeR();
	    Title();
	    Space();
	}
}

