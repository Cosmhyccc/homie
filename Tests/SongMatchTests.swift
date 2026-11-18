import Foundation
@main struct SongMatchTests {
 static func main() {
  let songs=[("Janice STFU","Drake"),("Different Song","Drake"),("Janice SDFU","Other Artist")]
  precondition(SongMatch.best(title:"Janice SDFU",artist:"Drake",candidates:songs)==0)
  precondition(SongMatch.best(title:"Billie Jeen",artist:"Michael Jackson",candidates:[("Billie Jean","Michael Jackson")])==0)
  precondition(SongMatch.best(title:"Hey",artist:"",candidates:[("Her","Artist")])==nil)
  precondition(SongMatch.best(title:"abcdefg",artist:"Artist",candidates:[("abcxefg","Artist"),("abcdxfg","Artist")])==nil)
  precondition(SongMatch.best(title:"Different Song",artist:"Wrong Artist",candidates:songs)==nil)
  precondition(SongMatch.best(title:"Janice STFU",artist:"Drake",candidates:songs)==0)
  precondition(SongMatch.best(title:"Janis STFU",artist:"Drake",candidates:songs)==0)
  precondition(SongMatch.best(title:"Janis STFU",artist:"",candidates:[("STFU!","Rina Sawayama"),("Janice STFU","Drake")])==1)
  precondition(SongMatch.best(title:"Janice STFU",artist:"",candidates:[("Janice STFU","Drake"),("Janice STFU","Cover Artist")])==nil)
  print("PASS catalog typo, exact title, wrong artist, ambiguity and short-title gates")
 }
}
