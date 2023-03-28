using System;
namespace Chapter_Exercises
{
    class Temperature
    {
        static void Main()
        {
            double fahrenheitTemperature;
            double convertedValue;

            fahrenheitTemperature = GetFahrenheit();
            convertedValue = ConvertToCelsius(fahrenheitTemperature);
            DisplayTemperatures(fahrenheitTemperature, convertedValue);
            Console.ReadKey();
        }
        static double GetFahrenheit()
        {
            double fahrenheitTemperature;
            Console.WriteLine("Enter temperature in fahrenheit: ");
            fahrenheitTemperature = Convert.ToDouble(Console.ReadLine());
            return fahrenheitTemperature;
        }
        static double ConvertToCelsius(double fahrenheitTemperature)
        {
            double convertedValue;
            convertedValue = (fahrenheitTemperature - 32) * 5 / 9;
            return convertedValue;
        }
        static void DisplayTemperatures(double inputValue, double convertedValue)
        {
            Console.WriteLine("{0} degrees fahrenheit is equal to {1} degrees celsius.", inputValue, convertedValue);
        }
    }
}