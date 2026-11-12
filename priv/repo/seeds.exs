# Deterministic MarryLocal test dataset.
#
# Run with:
#
#     mix run priv/repo/seeds.exs
#
# Or from a compiled release:
#
#     bin/marrylocal eval "Marrylocal.Release.seed()"
#
# Every account uses the same test password and a reserved `.test` email domain.
# Re-running the script removes prior `.test` accounts before inserting again.

import Ecto.Query

alias Marrylocal.Repo
alias Marrylocal.Accounts.{IdentityVerification, User}

password = "Password123!"

metros = %{
  "Mumbai" => %{
    slug: "mumbai",
    state: "Maharashtra",
    latitude: 19.0760,
    longitude: 72.8777
  },
  "Bangalore" => %{
    slug: "bangalore",
    state: "Karnataka",
    latitude: 12.9716,
    longitude: 77.5946
  },
  "Hyderabad" => %{
    slug: "hyderabad",
    state: "Telangana",
    latitude: 17.3850,
    longitude: 78.4867
  },
  "Delhi" => %{
    slug: "delhi",
    state: "Delhi",
    latitude: 28.6139,
    longitude: 77.2090
  }
}

# Small deterministic offsets keep each metro cluster within roughly 1-2 km.
coordinate_offsets = [
  {0.0000, 0.0000},
  {0.0045, 0.0028},
  {-0.0036, 0.0052},
  {0.0062, -0.0041},
  {-0.0058, -0.0032},
  {0.0024, -0.0065},
  {-0.0071, 0.0014},
  {0.0083, 0.0058}
]

profiles = [
  # Mumbai
  %{
    first: "Rahul",
    last: "Sharma",
    gender: "Male",
    age: 28,
    month: 3,
    day: 14,
    city: "Mumbai",
    language: "Hindi",
    religion: "Hindu",
    community: "Brahmin Smartha",
    caste: "Smartha",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "rahul_sharma",
    bio:
      "Product manager in Lower Parel who spends weekends trekking the Sahyadris and trying new Maharashtrian thalis."
  },
  %{
    first: "Sneha",
    last: "Patil",
    gender: "Female",
    age: 25,
    month: 7,
    day: 22,
    city: "Mumbai",
    language: "Marathi",
    religion: "Hindu",
    community: "Maratha",
    caste: "Patil",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "sneha_patil",
    bio:
      "Architect in Bandra, trained in Bharatanatyam, and happiest planning family dinners around fresh coastal seafood."
  },
  %{
    first: "Aditya",
    last: "Kulkarni",
    gender: "Male",
    age: 30,
    month: 11,
    day: 3,
    city: "Mumbai",
    language: "Marathi",
    religion: "Hindu",
    community: "Brahmin Deshastha",
    caste: "Deshastha",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "aditya_kulkarni",
    bio:
      "Data scientist in Powai who runs the Marine Drive loop at sunrise and collects vintage Marathi vinyl."
  },
  %{
    first: "Rohan",
    last: "Mehta",
    gender: "Male",
    age: 27,
    month: 5,
    day: 9,
    city: "Mumbai",
    language: "Gujarati",
    religion: "Hindu",
    community: "Vania",
    caste: "Vania",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "rohan_mehta",
    bio:
      "Family business in Dadar, a devoted street-food explorer, and a weekend volunteer at a local animal shelter."
  },
  %{
    first: "Ishaan",
    last: "Qureshi",
    gender: "Male",
    age: 32,
    month: 2,
    day: 18,
    city: "Mumbai",
    language: "Urdu",
    religion: "Muslim",
    community: "Muslim Sheikh",
    caste: "Sheikh",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "ishaan_qureshi",
    bio:
      "Civil engineer in Andheri, fluent in Urdu shayari, and always ready for a long drive down the Konkan coast."
  },
  %{
    first: "Ananya",
    last: "Iyer",
    gender: "Female",
    age: 26,
    month: 9,
    day: 6,
    city: "Mumbai",
    language: "Tamil",
    religion: "Hindu",
    community: "Brahmin Iyer",
    caste: "Iyer",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "ananya_iyer",
    bio:
      "Brand strategist in Worli who loves Carnatic music, filter coffee, and quiet Sundays by the sea."
  },
  %{
    first: "Farah",
    last: "Ansari",
    gender: "Female",
    age: 29,
    month: 12,
    day: 11,
    city: "Mumbai",
    language: "Urdu",
    religion: "Muslim",
    community: "Muslim Ansari",
    caste: "Ansari",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "farah_ansari",
    bio:
      "School teacher in Kurla, a passionate home baker, and the person who keeps every family celebration organised."
  },
  %{
    first: "Nicole",
    last: "D'Souza",
    gender: "Female",
    age: 24,
    month: 6,
    day: 25,
    city: "Mumbai",
    language: "Konkani",
    religion: "Christian",
    community: "Roman Catholic",
    caste: "Mangalorean",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "nicole_dsouza",
    bio:
      "UX designer in Bandra, choir singer at her parish, and a beach-cleanup regular when the monsoon clears."
  },

  # Bangalore
  %{
    first: "Priya",
    last: "Gowda",
    gender: "Female",
    age: 26,
    month: 4,
    day: 17,
    city: "Bangalore",
    language: "Kannada",
    religion: "Hindu",
    community: "Vokkaliga",
    caste: "Gowda",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "priya_gowda",
    bio:
      "Software engineer in Whitefield who grows herbs on her balcony and spends free weekends at Coorg homestays."
  },
  %{
    first: "Karthik",
    last: "Rao",
    gender: "Male",
    age: 29,
    month: 8,
    day: 8,
    city: "Bangalore",
    language: "Kannada",
    religion: "Hindu",
    community: "Brahmin Smartha",
    caste: "Smartha",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "karthik_rao",
    bio:
      "Platform engineer in Indiranagar, a serious badminton player, and a filter-coffee loyalist."
  },
  %{
    first: "Meera",
    last: "Shetty",
    gender: "Female",
    age: 31,
    month: 1,
    day: 26,
    city: "Bangalore",
    language: "Tulu",
    religion: "Hindu",
    community: "Bunt (Shetty)",
    caste: "Shetty",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "meera_shetty",
    bio:
      "Investment analyst in Koramangala who loves Yakshagana, coastal cuisine, and long drives to Mangalore."
  },
  %{
    first: "Vikram",
    last: "Hegde",
    gender: "Male",
    age: 33,
    month: 10,
    day: 13,
    city: "Bangalore",
    language: "Kannada",
    religion: "Hindu",
    community: "Brahmin Havyaka",
    caste: "Havyaka",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "vikram_hegde",
    bio:
      "Ayurvedic doctor in Jayanagar, a weekend farmer near Sirsi, and a patient listener with a dry sense of humour."
  },
  %{
    first: "Nandini",
    last: "Reddy",
    gender: "Female",
    age: 28,
    month: 3,
    day: 30,
    city: "Bangalore",
    language: "Telugu",
    religion: "Hindu",
    community: "Reddy",
    caste: "Reddy",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "nandini_reddy",
    bio:
      "Product designer in HSR Layout, trained in Kuchipudi, and always looking for the city's best dosa."
  },
  %{
    first: "Joseph",
    last: "D'Souza",
    gender: "Male",
    age: 34,
    month: 11,
    day: 19,
    city: "Bangalore",
    language: "Konkani",
    religion: "Christian",
    community: "Roman Catholic",
    caste: "Mangalorean",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "joseph_dsouza",
    bio:
      "Operations lead in Electronic City, a parish volunteer, and a weekend cyclist on the Nandi Hills route."
  },
  %{
    first: "Ayesha",
    last: "Khan",
    gender: "Female",
    age: 23,
    month: 7,
    day: 4,
    city: "Bangalore",
    language: "Urdu",
    religion: "Muslim",
    community: "Muslim Syed",
    caste: "Syed",
    education: "Bachelors level",
    economic: "Middleclass",
    job: false,
    handle: "ayesha_khan",
    bio:
      "Final-year design student in Malleshwaram, an illustrator, and a devoted chai-and-bookshop person."
  },
  %{
    first: "Sandeep",
    last: "Naik",
    gender: "Male",
    age: 35,
    month: 5,
    day: 21,
    city: "Bangalore",
    language: "Kannada",
    religion: "Hindu",
    community: "Naik",
    caste: "Naik",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "sandeep_naik",
    bio:
      "School principal in Rajajinagar, a theatre enthusiast, and a patient mentor to first-generation students."
  },

  # Hyderabad
  %{
    first: "Arjun",
    last: "Reddy",
    gender: "Male",
    age: 31,
    month: 2,
    day: 12,
    city: "Hyderabad",
    language: "Telugu",
    religion: "Hindu",
    community: "Reddy",
    caste: "Reddy",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "arjun_reddy",
    bio:
      "Fintech product lead in Gachibowli, a weekend cricketer, and a serious collector of Telugu film soundtracks."
  },
  %{
    first: "Kavya",
    last: "Rao",
    gender: "Female",
    age: 27,
    month: 9,
    day: 23,
    city: "Hyderabad",
    language: "Telugu",
    religion: "Hindu",
    community: "Kamma",
    caste: "Kamma",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "kavya_rao",
    bio:
      "Clinical psychologist in Banjara Hills who loves Hyderabad's old-city food trails and quiet classical concerts."
  },
  %{
    first: "Rohit",
    last: "Varma",
    gender: "Male",
    age: 26,
    month: 6,
    day: 15,
    city: "Hyderabad",
    language: "Telugu",
    religion: "Hindu",
    community: "Kapu",
    caste: "Kapu",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "rohit_varma",
    bio:
      "Mechanical engineer in Secunderabad, a gym regular, and the unofficial photographer for every family function."
  },
  %{
    first: "Divya",
    last: "Reddy",
    gender: "Female",
    age: 24,
    month: 12,
    day: 2,
    city: "Hyderabad",
    language: "Telugu",
    religion: "Hindu",
    community: "Reddy",
    caste: "Reddy",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "divya_reddy",
    bio:
      "Business analyst in Madhapur, a Bharatanatyam student, and an enthusiastic host for weekend brunches."
  },
  %{
    first: "Imran",
    last: "Ali",
    gender: "Male",
    age: 33,
    month: 3,
    day: 7,
    city: "Hyderabad",
    language: "Urdu",
    religion: "Muslim",
    community: "Muslim Syed",
    caste: "Syed",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "imran_ali",
    bio:
      "Architect in Jubilee Hills, a lover of Deccani poetry, and a patient restorer of old Hyderabadi homes."
  },
  %{
    first: "Lakshmi",
    last: "Naidu",
    gender: "Female",
    age: 30,
    month: 8,
    day: 27,
    city: "Hyderabad",
    language: "Telugu",
    religion: "Hindu",
    community: "Naidu",
    caste: "Naidu",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "lakshmi_naidu",
    bio:
      "HR leader in Kondapur, a Kuchipudi teacher on weekends, and a firm believer in family Sunday lunches."
  },
  %{
    first: "Suresh",
    last: "Kumar",
    gender: "Male",
    age: 35,
    month: 1,
    day: 9,
    city: "Hyderabad",
    language: "Telugu",
    religion: "Hindu",
    community: "Brahmin Madhwa",
    caste: "Madhwa",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "suresh_kumar",
    bio:
      "Chartered accountant in Ameerpet, a temple volunteer, and a dependable guide for anyone new to the city."
  },

  # Delhi
  %{
    first: "Neha",
    last: "Verma",
    gender: "Female",
    age: 27,
    month: 10,
    day: 5,
    city: "Delhi",
    language: "Punjabi",
    religion: "Hindu",
    community: "Khatri",
    caste: "Khatri",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "neha_verma",
    bio:
      "Marketing manager in Gurugram, a street-food connoisseur, and a weekend pottery-class regular."
  },
  %{
    first: "Kabir",
    last: "Malhotra",
    gender: "Male",
    age: 30,
    month: 4,
    day: 28,
    city: "Delhi",
    language: "Punjabi",
    religion: "Hindu",
    community: "Arora",
    caste: "Arora",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "kabir_malhotra",
    bio:
      "Startup founder in Saket, a squash player, and a devoted host for Sunday brunch with friends."
  },
  %{
    first: "Simran",
    last: "Kaur",
    gender: "Female",
    age: 25,
    month: 6,
    day: 18,
    city: "Delhi",
    language: "Punjabi",
    religion: "Sikh",
    community: "Sikh Khatri",
    caste: "Khatri",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "simran_kaur",
    bio:
      "Fashion buyer in Khan Market, a gurdwara volunteer, and a collector of handloom textiles."
  },
  %{
    first: "Aarav",
    last: "Gupta",
    gender: "Male",
    age: 29,
    month: 2,
    day: 24,
    city: "Delhi",
    language: "Hindi",
    religion: "Hindu",
    community: "Agarwal",
    caste: "Agarwal",
    education: "Masters level",
    economic: "Above Middleclass",
    job: true,
    handle: "aarav_gupta",
    bio:
      "Management consultant in Connaught Place, a marathon runner, and a home cook famous for his dal makhani."
  },
  %{
    first: "Riya",
    last: "Sharma",
    gender: "Female",
    age: 23,
    month: 7,
    day: 31,
    city: "Delhi",
    language: "Hindi",
    religion: "Hindu",
    community: "Brahmin Smartha",
    caste: "Smartha",
    education: "Bachelors level",
    economic: "Middleclass",
    job: false,
    handle: "riya_sharma",
    bio:
      "Law student in North Campus, a debating champion, and a weekend explorer of Delhi's heritage walks."
  },
  %{
    first: "Zoya",
    last: "Siddiqui",
    gender: "Female",
    age: 32,
    month: 11,
    day: 16,
    city: "Delhi",
    language: "Urdu",
    religion: "Muslim",
    community: "Muslim Siddiqui",
    caste: "Siddiqui",
    education: "Masters level",
    economic: "Middleclass",
    job: true,
    handle: "zoya_siddiqui",
    bio:
      "Journalist in Jangpura, a documentary film lover, and a patient listener with a wide circle of friends."
  },
  %{
    first: "Manish",
    last: "Jat",
    gender: "Male",
    age: 34,
    month: 5,
    day: 3,
    city: "Delhi",
    language: "Hindi",
    religion: "Hindu",
    community: "Jat",
    caste: "Jat",
    education: "Bachelors level",
    economic: "Middleclass",
    job: true,
    handle: "manish_jat",
    bio:
      "Civil services aspirant from Dwarka, a kabaddi fan, and a disciplined early riser who loves long cycle rides."
  }
]

# ---------------------------------------------------------------------------
# High-density Bangalore cluster
#
# 50 additional profiles are scattered inside a +/-0.08 degree box around the
# Bangalore core. A fixed RNG seed keeps the coordinates reproducible while
# still producing realistic neighbourhood-level variance.
# ---------------------------------------------------------------------------
:rand.seed(:exsss, {12_9716, 77_5946, 2_026})

dense_demographics = [
  %{religion: "Hindu", community: "Vokkaliga", caste: "Vokkaliga"},
  %{religion: "Hindu", community: "Brahmin Smartha", caste: "Smartha"},
  %{religion: "Hindu", community: "Brahmin Iyer", caste: "Iyer"},
  %{religion: "Hindu", community: "Brahmin Madhwa", caste: "Madhwa"},
  %{religion: "Hindu", community: "Lingayath", caste: "Lingayath"},
  %{religion: "Hindu", community: "Reddy", caste: "Reddy"},
  %{religion: "Hindu", community: "Naidu", caste: "Naidu"},
  %{religion: "Hindu", community: "Kamma", caste: "Kamma"},
  %{religion: "Hindu", community: "Kapu", caste: "Kapu"},
  %{religion: "Hindu", community: "Bunt (Shetty)", caste: "Shetty"},
  %{religion: "Hindu", community: "Nair", caste: "Nair"},
  %{religion: "Hindu", community: "Chettiar", caste: "Chettiar"},
  %{religion: "Muslim", community: "Muslim Syed", caste: "Syed"},
  %{religion: "Muslim", community: "Muslim Sheikh", caste: "Sheikh"},
  %{religion: "Muslim", community: "Muslim Ansari", caste: "Ansari"},
  %{religion: "Christian", community: "Roman Catholic", caste: "Mangalorean"},
  %{religion: "Christian", community: "Syrian Catholic", caste: "Syrian"},
  %{religion: "Jain", community: "Jain Oswal", caste: "Oswal"},
  %{religion: "Hindu", community: "Maratha", caste: "Maratha"},
  %{religion: "Hindu", community: "Naik", caste: "Naik"},
  %{religion: "Sikh", community: "Sikh Khatri", caste: "Khatri"},
  %{religion: "Hindu", community: "Khatri", caste: "Khatri"},
  %{religion: "Hindu", community: "Agarwal", caste: "Agarwal"},
  %{religion: "Hindu", community: "Arora", caste: "Arora"},
  %{religion: "Hindu", community: "Brahmin Deshastha", caste: "Deshastha"}
]

dense_male_names = [
  "Aarav",
  "Vihaan",
  "Aditya",
  "Rohan",
  "Karthik",
  "Arjun",
  "Siddharth",
  "Nikhil",
  "Pranav",
  "Rahul",
  "Varun",
  "Aniket",
  "Harsh",
  "Kunal",
  "Manav",
  "Rishabh",
  "Sameer",
  "Tanmay",
  "Yash",
  "Aakash",
  "Dhruv",
  "Gaurav",
  "Mohit",
  "Naveen",
  "Omkar"
]

dense_female_names = [
  "Ananya",
  "Priya",
  "Kavya",
  "Nandini",
  "Meera",
  "Sneha",
  "Divya",
  "Aisha",
  "Riya",
  "Pooja",
  "Shreya",
  "Isha",
  "Aditi",
  "Neha",
  "Tanvi",
  "Sanya",
  "Radhika",
  "Deepa",
  "Swati",
  "Pallavi",
  "Aishwarya",
  "Bhavya",
  "Charul",
  "Diya",
  "Esha"
]

dense_last_names = [
  "Rao",
  "Gowda",
  "Reddy",
  "Shetty",
  "Hegde",
  "Iyer",
  "Menon",
  "Nair",
  "Patel",
  "Desai",
  "Kulkarni",
  "Joshi",
  "Verma",
  "Gupta",
  "Malhotra",
  "Singh",
  "Khan",
  "D'Souza",
  "Fernandes",
  "Naik",
  "Bhat",
  "Pai",
  "Kamath",
  "Shenoy",
  "Acharya"
]

dense_languages = [
  "Kannada",
  "Tamil",
  "Telugu",
  "Hindi",
  "Urdu",
  "Malayalam",
  "Marathi",
  "Konkani",
  "Gujarati",
  "Bengali"
]

dense_occupations = [
  "Software Engineer",
  "Product Manager",
  "Data Scientist",
  "UX Designer",
  "Business Analyst",
  "DevOps Engineer",
  "QA Engineer",
  "Marketing Manager",
  "Financial Analyst",
  "HR Specialist",
  "Architect",
  "Doctor",
  "Teacher",
  "Consultant",
  "Sales Manager",
  "Research Associate",
  "Content Strategist",
  "Operations Manager",
  "Civil Engineer",
  "Mechanical Engineer"
]

dense_neighborhoods = [
  "Indiranagar",
  "Koramangala",
  "Whitefield",
  "HSR Layout",
  "Jayanagar",
  "Malleshwaram",
  "Rajajinagar",
  "Bellandur",
  "Marathahalli",
  "Electronic City"
]

dense_hobbies = [
  "filter coffee walks",
  "weekend cycling",
  "live music gigs",
  "street-food trails",
  "badminton",
  "pottery classes",
  "trekking",
  "bookshops and cafes",
  "Carnatic music",
  "running clubs"
]

dense_educations = ["High School", "Plus 2 level", "Bachelors level", "Masters level"]
dense_economics = ["Below Middleclass", "Middleclass", "Above Middleclass"]

dense_profiles =
  Enum.map(1..50, fn index ->
    gender = if rem(index, 2) == 1, do: "Male", else: "Female"

    first_name =
      if gender == "Male" do
        Enum.at(dense_male_names, div(index - 1, 2))
      else
        Enum.at(dense_female_names, div(index - 2, 2))
      end

    last_name = Enum.at(dense_last_names, rem(index * 7, length(dense_last_names)))
    demographic = Enum.at(dense_demographics, rem(index - 1, length(dense_demographics)))
    occupation = Enum.at(dense_occupations, rem(index - 1, length(dense_occupations)))
    neighborhood = Enum.at(dense_neighborhoods, rem(index * 3, length(dense_neighborhoods)))
    hobby = Enum.at(dense_hobbies, rem(index * 5, length(dense_hobbies)))
    age = 22 + rem(index - 1, 12)
    month = rem(index * 3, 12) + 1
    day = rem(index * 5, 28) + 1

    lat_offset = (:rand.uniform() - 0.5) * 0.16 + (index - 25) * 0.00001
    lng_offset = (:rand.uniform() - 0.5) * 0.16 + (index - 25) * 0.00001

    %{
      first: first_name,
      last: last_name,
      gender: gender,
      age: age,
      month: month,
      day: day,
      city: "Bangalore",
      language: Enum.at(dense_languages, rem(index - 1, length(dense_languages))),
      religion: demographic.religion,
      community: demographic.community,
      caste: demographic.caste,
      education: Enum.at(dense_educations, rem(index * 2, length(dense_educations))),
      economic: Enum.at(dense_economics, rem(index, length(dense_economics))),
      job: rem(index, 7) != 0,
      handle: "#{String.downcase(first_name)}_b#{index}",
      bio:
        "#{occupation} in #{neighborhood}. Enjoys #{hobby} and weekend meetups across Bangalore.",
      email: "bangalore.dense.user#{index}@marrylocal.test",
      latitude: 12.9716 + lat_offset,
      longitude: 77.5946 + lng_offset
    }
  end)

all_profiles = profiles ++ dense_profiles

email_for = fn profile ->
  case Map.get(profile, :email) do
    email when is_binary(email) ->
      email

    _ ->
      metro = Map.fetch!(metros, profile.city)
      "#{metro.slug}.demo.#{String.downcase(profile.first)}@marrylocal.test"
  end
end

age_on = fn date_of_birth ->
  today = Date.utc_today()
  had_birthday? = {today.month, today.day} >= {date_of_birth.month, date_of_birth.day}
  today.year - date_of_birth.year - if(had_birthday?, do: 0, else: 1)
end

birth_date_for = fn age, month, day ->
  today = Date.utc_today()
  candidate = Date.new!(today.year - age, month, day)

  if age_on.(candidate) == age do
    candidate
  else
    Date.new!(today.year - age - 1, month, day)
  end
end

now = DateTime.utc_now() |> DateTime.truncate(:second)

# Hash once per profile before opening the transaction. Each account gets its own
# salt, and the transaction never stays idle while PBKDF2 runs.
password_hashes =
  Map.new(all_profiles, fn profile ->
    {email_for.(profile), Pbkdf2.hash_pwd_salt(password)}
  end)

{:ok, {deleted_count, seeded_profiles}} =
  Repo.transaction(fn ->
    {deleted_count, _} =
      Repo.delete_all(
        from user in User,
          where: like(user.email, "%.test")
      )

    seeded =
      all_profiles
      |> Enum.with_index(1)
      |> Enum.map(fn {profile, index} ->
        metro = Map.fetch!(metros, profile.city)

        {lat_offset, lng_offset} =
          Enum.at(coordinate_offsets, rem(index - 1, length(coordinate_offsets)))

        {latitude, longitude} =
          case {Map.get(profile, :latitude), Map.get(profile, :longitude)} do
            {lat, lng} when is_number(lat) and is_number(lng) ->
              {lat, lng}

            _ ->
              {metro.latitude + lat_offset, metro.longitude + lng_offset}
          end

        email = email_for.(profile)
        password_hash = Map.fetch!(password_hashes, email)
        shortid = "seed" <> String.pad_leading(Integer.to_string(index), 5, "0")
        referral_code = "SEED" <> String.pad_leading(Integer.to_string(index), 6, "0")
        phone_number = "+9198" <> String.pad_leading(Integer.to_string(index), 8, "0")

        registration_attrs = %{
          email: email,
          password: password,
          password_confirmation: password,
          first_name: profile.first,
          last_name: profile.last,
          phone_number: phone_number,
          date_of_birth: birth_date_for.(profile.age, profile.month, profile.day),
          gender: profile.gender,
          city: profile.city,
          state: metro.state,
          language: profile.language,
          religion: profile.religion,
          community: profile.community,
          caste: profile.caste,
          user_handle: profile.handle
        }

        user =
          %User{}
          |> User.registration_changeset(registration_attrs, hash_password: false)
          |> Ecto.Changeset.put_change(:hashed_password, password_hash)
          |> Repo.insert!()

        user =
          user
          |> User.profile_changeset(%{
            "bio" => profile.bio,
            "education_level" => profile.education,
            "economic_status" => profile.economic,
            "job_status" => profile.job,
            "show_community" => true,
            "show_phone" => false,
            "show_facebook" => false,
            "show_instagram" => false,
            "show_in_other_religion_people_search" => true
          })
          |> Ecto.Changeset.change(%{
            confirmed_at: now,
            email_verified: true,
            terms_accepted: true,
            onetime_fees_paid: true,
            onetime_fees_required: false,
            shortid: shortid,
            referral_code: referral_code,
            date_of_activation: now,
            images: [],
            user_state: :active
          })
          |> Repo.update!()

        user =
          user
          |> User.location_changeset(%{
            latitude: latitude,
            longitude: longitude
          })
          |> Repo.update!()

        if is_nil(user.location) do
          raise "PostGIS location was not stored for #{email}"
        end

        if user.age != profile.age do
          raise "Age mismatch for #{email}: expected #{profile.age}, got #{user.age}"
        end

        {email, profile}
      end)

    {deleted_count, seeded}
  end)

broad_emails = Enum.map(profiles, &email_for.(&1))
dense_emails = Enum.map(dense_profiles, &email_for.(&1))

seeded_users =
  Repo.all(
    from user in User,
      where: like(user.email, "%.test")
  )

broad_users =
  Repo.all(
    from user in User,
      where: user.email in ^broad_emails
  )

dense_users =
  Repo.all(
    from user in User,
      where: user.email in ^dense_emails
  )

broad_male_count = Enum.count(broad_users, &(&1.gender == "Male"))
broad_female_count = Enum.count(broad_users, &(&1.gender == "Female"))
dense_male_count = Enum.count(dense_users, &(&1.gender == "Male"))
dense_female_count = Enum.count(dense_users, &(&1.gender == "Female"))

confirmed_count =
  Enum.count(seeded_users, &(not is_nil(&1.confirmed_at) and &1.email_verified))

located_count = Enum.count(seeded_users, &(not is_nil(&1.location)))
broad_ages = Enum.map(broad_users, & &1.age)
dense_ages = Enum.map(dense_users, & &1.age)

haversine_km = fn lat1, lon1, lat2, lon2 ->
  to_radians = fn degrees -> degrees * :math.pi() / 180.0 end
  dlat = to_radians.(lat2 - lat1)
  dlon = to_radians.(lon2 - lon1)

  a =
    :math.pow(:math.sin(dlat / 2), 2) +
      :math.cos(to_radians.(lat1)) *
        :math.cos(to_radians.(lat2)) *
        :math.pow(:math.sin(dlon / 2), 2)

  2 * 6_371.0 * :math.asin(:math.sqrt(a))
end

dense_distances =
  Enum.map(dense_users, fn user ->
    haversine_km.(12.9716, 77.5946, user.latitude, user.longitude)
  end)

dense_max_distance = Enum.max(dense_distances)

dense_coordinate_count =
  dense_users
  |> Enum.map(fn user -> {user.latitude, user.longitude} end)
  |> Enum.uniq()
  |> length()

if length(seeded_users) != 80 do
  raise "Expected 80 seeded users, found #{length(seeded_users)}"
end

if length(broad_users) != 30 do
  raise "Expected 30 broad city profiles, found #{length(broad_users)}"
end

if length(dense_users) != 50 do
  raise "Expected 50 dense Bangalore profiles, found #{length(dense_users)}"
end

if broad_male_count != 15 or broad_female_count != 15 do
  raise "Expected 15/15 broad gender split, got #{broad_male_count} male and #{broad_female_count} female"
end

if dense_male_count != 25 or dense_female_count != 25 do
  raise "Expected 25/25 dense gender split, got #{dense_male_count} male and #{dense_female_count} female"
end

if confirmed_count != 80 do
  raise "Expected all 80 users to be email-verified, found #{confirmed_count}"
end

if located_count != 80 do
  raise "Expected all 80 users to have PostGIS locations, found #{located_count}"
end

if Enum.min(broad_ages) < 23 or Enum.max(broad_ages) > 35 do
  raise "Expected broad ages between 23 and 35, got #{Enum.min(broad_ages)}..#{Enum.max(broad_ages)}"
end

if Enum.min(dense_ages) < 22 or Enum.max(dense_ages) > 33 do
  raise "Expected dense ages between 22 and 33, got #{Enum.min(dense_ages)}..#{Enum.max(dense_ages)}"
end

if dense_coordinate_count != 50 do
  raise "Expected 50 distinct dense coordinates, found #{dense_coordinate_count}"
end

if dense_max_distance > 25.0 do
  raise "Dense profile outside 25km radius: #{Float.round(dense_max_distance, 2)}km"
end

primary_emails = [
  "mumbai.demo.rahul@marrylocal.test",
  "bangalore.demo.priya@marrylocal.test",
  "hyderabad.demo.arjun@marrylocal.test",
  "delhi.demo.neha@marrylocal.test",
  "mumbai.demo.sneha@marrylocal.test"
]

primary_profiles =
  Enum.map(primary_emails, fn email ->
    case Enum.find(seeded_profiles, fn {seeded_email, _profile} -> seeded_email == email end) do
      {^email, profile} ->
        profile

      nil ->
        raise "Primary seed account missing: #{email}"
    end
  end)

IO.puts("")
IO.puts("MarryLocal deterministic test data loaded")
IO.puts("Removed prior .test accounts: #{deleted_count}")
IO.puts("Seeded profiles: #{length(seeded_users)} (30 broad + 50 dense)")

IO.puts(
  "Broad city profiles: #{length(broad_users)} (#{broad_male_count} male / #{broad_female_count} female, ages #{Enum.min(broad_ages)}-#{Enum.max(broad_ages)})"
)

IO.puts(
  "Dense Bangalore profiles: #{length(dense_users)} (#{dense_male_count} male / #{dense_female_count} female, ages #{Enum.min(dense_ages)}-#{Enum.max(dense_ages)})"
)

IO.puts("PostGIS locations ready: #{located_count}/#{length(seeded_users)}")
IO.puts("Dense max radius from Bangalore core: #{Float.round(dense_max_distance, 2)}km")
IO.puts("Password for every account: #{password}")
IO.puts("")
IO.puts("Primary login accounts")

IO.puts(
  "------------------------------------------------------------------------------------------"
)

Enum.each(primary_profiles, fn profile ->
  name = "#{profile.first} #{profile.last}"
  community_label = profile.community |> String.split(" ") |> hd()

  IO.puts(
    "#{String.pad_trailing(email_for.(profile), 40)} | #{String.pad_trailing(name, 16)} | #{profile.gender}, #{profile.age}, #{profile.language}, #{community_label}"
  )
end)

IO.puts(
  "------------------------------------------------------------------------------------------"
)

IO.puts("")

IO.puts(
  "Generated 50 high-density local testing profiles within a 25km radius of the Bangalore core."
)

IO.puts("")

# Billing/restriction test profile for the annual service-fee gate.
fee_test_email = "delhi.fee.test@marrylocal.test"

unless Repo.get_by(User, email: fee_test_email) do
  %User{}
  |> User.registration_changeset(%{
    email: fee_test_email,
    password: password,
    password_confirmation: password,
    first_name: "Delhi",
    last_name: "FeeTest",
    phone_number: "+919800000099",
    birth_date: ~D[1995-01-01],
    gender: "Male",
    city: "Delhi",
    state: "Delhi",
    language: "Hindi",
    religion: "Hindu",
    community: "General",
    user_handle: "delhi_fee_test"
  })
  |> Ecto.Changeset.change(%{
    onetime_fees_required: true,
    onetime_fees_paid: false,
    force_verification_required: false
  })
  |> Repo.insert!()

  IO.puts("Billing gate test profile: #{fee_test_email} / #{password}")
end

# ---------------------------------------------------------------------------
# Administrative accounts for dashboard and review-queue verification
# ---------------------------------------------------------------------------

admin_specs = [
  %{
    email: "admin.santhosh@marrylocal.test",
    password: password,
    first_name: "Santhosh",
    last_name: "Admin",
    user_handle: "admin_santhosh",
    phone_number: "9000000001",
    city: "Hyderabad",
    state: "Telangana",
    age: 30,
    month: 1,
    day: 15,
    gender: "Male",
    shortid: "admin00001",
    referral_code: "ADMIN00001"
  },
  %{
    email: "admin.moderator@marrylocal.test",
    password: password,
    first_name: "Meera",
    last_name: "Moderator",
    user_handle: "admin_meera",
    phone_number: "9000000002",
    city: "Bangalore",
    state: "Karnataka",
    age: 29,
    month: 6,
    day: 20,
    gender: "Female",
    shortid: "admin00002",
    referral_code: "ADMIN00002"
  }
]

# The main transaction above already removes every `.test` account. This second
# sweep explicitly covers admin rows created outside the deterministic dataset
# (including the legacy `.admin.test` suffix) so repeated runs never collide.
Repo.delete_all(
  from user in User,
    where:
      like(user.email, "%.admin.test") or
        (like(user.email, "%@marrylocal.test") and user.role == :admin)
)

admin_users =
  Enum.map(admin_specs, fn spec ->
    user =
      %User{}
      |> User.registration_changeset(%{
        email: spec.email,
        password: spec.password,
        password_confirmation: spec.password,
        first_name: spec.first_name,
        last_name: spec.last_name,
        phone_number: spec.phone_number,
        birth_date: birth_date_for.(spec.age, spec.month, spec.day),
        gender: spec.gender,
        city: spec.city,
        state: spec.state,
        language: "English",
        religion: "Hindu",
        community: "General",
        caste: "General",
        user_handle: spec.user_handle
      })
      |> Repo.insert!()

    user
    |> Ecto.Changeset.change(%{
      role: :admin,
      user_state: :active,
      confirmed_at: now,
      email_verified: true,
      terms_accepted: true,
      is_beta_tester: true,
      onetime_fees_paid: true,
      onetime_fees_required: false,
      force_verification_required: false,
      shortid: spec.shortid,
      referral_code: spec.referral_code,
      date_of_activation: now
    })
    |> Repo.update!()
  end)

Enum.each(admin_users, fn admin ->
  unless admin.role == :admin and admin.user_state == :active and admin.email_verified and
           admin.terms_accepted and admin.is_beta_tester and not is_nil(admin.confirmed_at) do
    raise "Admin onboarding gates were not cleared for #{admin.email}"
  end
end)

# ---------------------------------------------------------------------------
# Pending identity-verification samples for the admin review queue
# ---------------------------------------------------------------------------

verification_specs = [
  %{
    email: "mumbai.demo.rahul@marrylocal.test",
    document_type: "aadhaar",
    document_number: "SEED-RAHUL-AADHAAR-0001",
    document_key: "seed/verifications/rahul-aadhaar.jpg"
  },
  %{
    email: "bangalore.demo.priya@marrylocal.test",
    document_type: "passport",
    document_number: "SEED-PRIYA-PASSPORT-0002",
    document_key: "seed/verifications/priya-passport.jpg"
  }
]

verification_users =
  Enum.map(verification_specs, fn spec ->
    case Repo.get_by(User, email: spec.email) do
      %User{} = user ->
        user

      nil ->
        raise "Verification seed user is missing: #{spec.email}"
    end
  end)

verification_user_ids = Enum.map(verification_users, & &1.id)

Repo.delete_all(
  from verification in IdentityVerification,
    where: verification.user_id in ^verification_user_ids
)

verifications =
  Enum.zip(verification_specs, verification_users)
  |> Enum.map(fn {spec, user} ->
    %IdentityVerification{}
    |> Ecto.Changeset.change(%{
      user_id: user.id,
      document_type: spec.document_type,
      document_number: spec.document_number,
      document_image: %{file_name: spec.document_key, updated_at: nil},
      status: "pending_admin_review",
      rejection_reason: nil
    })
    |> Repo.insert!()
  end)

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------

IO.puts("")
IO.puts("================================================================================")
IO.puts("MarryLocal admin logins")
IO.puts("================================================================================")

Enum.each(admin_users, fn admin ->
  IO.puts("#{String.pad_trailing(admin.email, 40)} | Password: #{password} | Role: #{admin.role}")
end)

IO.puts("================================================================================")
IO.puts("Pending identity verifications for admin review: #{length(verifications)}")
IO.puts("  Rahul Sharma (Mumbai)  — Aadhaar  — pending_admin_review")
IO.puts("  Priya Gowda (Bangalore) — Passport — pending_admin_review")
IO.puts("================================================================================")
IO.puts("")
