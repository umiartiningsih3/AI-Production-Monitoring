Attribute VB_Name = "YieldOutput"
'=====================================================================
'  PBL PBLIF3-MD04 - Monitoring & Prediksi Produksi
'  Modul YieldOutput : POST data Excel ke SQL Server LOKAL.
'
'  Alur sama dengan macro produksi (Post_PONOutput, Post_DetailsReject2,
'  Post_DailyOutput2, Post_Productivity2, Test). Bedanya:
'   - database lokal di laptop (SQL Server 2022 / SQLEXPRESS)
'   - tanggal & angka dikirim dalam format netral (aman untuk Windows
'     berbahasa Indonesia yang memakai koma sebagai desimal)
'   - setiap sub memakai transaksi: kalau gagal, data tidak setengah masuk
'   - baris yang belum lengkap dilewati dan dilaporkan
'
'  Tombol POST memanggil Test. Setelah POST, web dashboard React
'  (http://localhost:3000) otomatis menampilkan data terbaru dalam
'  beberapa detik, termasuk prediksi XGBoost yang dihitung di SQL Server.
'=====================================================================
Option Explicit

'------------------- PENGATURAN DATABASE LOKAL -------------------
Public Const DB_SERVER As String = "LAPTOP-CAUU01V5\SQLEXPRESS"
Public Const DB_NAME As String = "PBL_MonitoringProduksi"
'-----------------------------------------------------------------

Private mDipanggilTest As Boolean   'True saat dipanggil dari Test (pesan digabung)
Private mRingkasan As String
Private mDilewati As String
Private mJumlahLewat As Long

'=====================================================================
'  KONEKSI & HELPER
'=====================================================================
Private Function BukaKoneksi() As Object
    Dim conn As Object, prov As Variant, pesan As String
    For Each prov In Array("MSOLEDBSQL19", "MSOLEDBSQL", "SQLNCLI11", "SQLOLEDB")
        Set conn = CreateObject("ADODB.Connection")
        conn.ConnectionTimeout = 10
        conn.CommandTimeout = 120
        On Error Resume Next
        If Left$(prov, 10) = "MSOLEDBSQL" Then
            conn.Open "Provider=" & prov & ";Data Source=" & DB_SERVER & ";Initial Catalog=" & DB_NAME & _
                      ";Integrated Security=SSPI;Use Encryption for Data=Optional;Trust Server Certificate=True;"
        Else
            conn.Open "Provider=" & prov & ";Data Source=" & DB_SERVER & ";Initial Catalog=" & DB_NAME & _
                      ";Integrated Security=SSPI;"
        End If
        If Err.Number = 0 Then
            On Error GoTo 0
            Set BukaKoneksi = conn
            Exit Function
        End If
        pesan = pesan & vbCrLf & "- " & prov & ": " & Err.Description
        Err.Clear
        On Error GoTo 0
    Next prov
    Err.Raise vbObjectError + 513, , "Tidak bisa terhubung ke SQL Server " & DB_SERVER & _
        " (database " & DB_NAME & ")." & vbCrLf & _
        "Pastikan service SQL Server (SQLEXPRESS) berjalan." & vbCrLf & Left$(pesan, 600)
End Function

Private Sub TutupKoneksi(ByRef conn As Object)
    On Error Resume Next
    If Not conn Is Nothing Then
        If conn.State = 1 Then conn.Close
    End If
    Set conn = Nothing
End Sub

'Teks -> N'...' (tanda kutip di-escape). Kosong -> ''
Private Function SqlTeks(ByVal v As Variant) As String
    Dim s As String
    If IsError(v) Or IsEmpty(v) Or IsNull(v) Then
        s = ""
    Else
        s = Trim$(CStr(v))
    End If
    s = Replace(Replace(s, vbCr, " "), vbLf, " ")
    SqlTeks = "N'" & Replace(s, "'", "''") & "'"
End Function

'Tanggal -> 'yyyy-mm-dd' (atau NULL)
Private Function SqlTgl(ByVal v As Variant) As String
    If IsTanggal(v) Then
        SqlTgl = "'" & Format$(CDate(v), "yyyy-mm-dd") & "'"
    Else
        SqlTgl = "NULL"
    End If
End Function

'Angka -> titik sebagai desimal. Kosong / "-" / error -> 0
Private Function SqlAngka(ByVal v As Variant) As String
    Dim d As Double
    d = Nz(v)
    SqlAngka = Replace(CStr(d), Application.International(xlDecimalSeparator), ".")
    If InStr(SqlAngka, "E") > 0 Then SqlAngka = Replace(Format$(d, "0.000000000"), Application.International(xlDecimalSeparator), ".")
End Function

Private Function SqlWaktu(ByVal v As Date) As String
    SqlWaktu = "'" & Format$(v, "yyyy-mm-dd hh:nn:ss") & "'"
End Function

Function Nz(val)
    If IsError(val) Then
        Nz = 0
    ElseIf IsEmpty(val) Or IsNull(val) Then
        Nz = 0
    ElseIf VarType(val) = vbString Then
        If IsNumeric(Trim$(val)) Then Nz = CDbl(Trim$(val)) Else Nz = 0
    ElseIf IsNumeric(val) Then
        Nz = CDbl(val)
    Else
        Nz = 0
    End If
End Function

Private Function IsTanggal(ByVal v As Variant) As Boolean
    If IsError(v) Or IsEmpty(v) Or IsNull(v) Then Exit Function
    If VarType(v) = vbDate Then
        IsTanggal = True
    ElseIf IsNumeric(v) Then
        IsTanggal = (v > 36526 And v < 73051)
    ElseIf VarType(v) = vbString Then
        IsTanggal = (Trim$(v) <> "" And IsDate(v))
    End If
End Function

Private Function Kosong(ByVal v As Variant) As Boolean
    If IsError(v) Then
        Kosong = False
    ElseIf IsEmpty(v) Or IsNull(v) Then
        Kosong = True
    Else
        Kosong = (Trim$(CStr(v)) = "")
    End If
End Function

Private Function AngkaValid(ByVal v As Variant) As Boolean
    If IsError(v) Then Exit Function
    If IsEmpty(v) Then AngkaValid = True: Exit Function
    If VarType(v) = vbString Then
        AngkaValid = (Trim$(v) = "" Or Trim$(v) = "-" Or IsNumeric(Trim$(v)))
    Else
        AngkaValid = IsNumeric(v)
    End If
End Function

'Bulan laporan file ini (dari sel B7 sheet ringkasan); Empty kalau tidak ada
Private Function BulanFile(ByVal ws As Worksheet) As Variant
    Dim v
    v = ws.Range("B7").Value
    If IsTanggal(v) Then BulanFile = DateSerial(Year(CDate(v)), Month(CDate(v)), 1) Else BulanFile = Empty
End Function

'Kondisi SQL: kolom berada di dalam bulan laporan
'Cari nomor kolom header PO (baris 3, kolom 1..26) berdasarkan judulnya,
'supaya macro bisa dipakai di file Lini Produk A maupun B walau posisi kolomnya beda
Private Function KolomHeader(ByVal ws As Worksheet, ByVal judul As String) As Long
    Dim c As Long, t As String
    For c = 1 To 26
        t = LCase$(Trim$(Replace(Replace(CStr(ws.Cells(3, c).Value), vbCr, " "), vbLf, " ")))
        If t = LCase$(judul) Or (Len(judul) > 2 And InStr(1, t, LCase$(judul)) = 1) Then KolomHeader = c: Exit Function
    Next c
    KolomHeader = 0
End Function

Private Function NilaiKolom(ByVal ws As Worksheet, ByVal B As Long, ByVal kol As Long) As Variant
    If kol > 0 Then NilaiKolom = ws.Cells(B, kol).Value Else NilaiKolom = Empty
End Function

Private Function RentangBulan(ByVal kolom As String, ByVal bln As Variant) As String
    RentangBulan = kolom & " >= '" & Format$(bln, "yyyy-mm-dd") & "' and " & kolom & " < '" & Format$(DateAdd("m", 1, bln), "yyyy-mm-dd") & "'"
End Function

Private Sub CatatLewat(ByVal sheetName As String, ByVal sel As String, ByVal alasan As String)
    mJumlahLewat = mJumlahLewat + 1
    If mJumlahLewat <= 8 Then
        mDilewati = mDilewati & vbCrLf & "- " & Trim$(sheetName) & " " & sel & ": " & alasan
    End If
End Sub

Private Sub SelesaiPost(ByVal judul As String, ByVal hasil As String)
    mRingkasan = mRingkasan & vbCrLf & "- " & judul & ": " & hasil
    If Not mDipanggilTest Then
        MsgBox "The Data was posted successfully" & vbCrLf & vbCrLf & judul & ": " & hasil & _
               IIf(mJumlahLewat > 0, vbCrLf & vbCrLf & mJumlahLewat & " baris dilewati:" & mDilewati, ""), _
               vbInformation, "POST"
        mJumlahLewat = 0: mDilewati = ""
    End If
End Sub

Private Sub GagalPost(ByVal judul As String, ByRef conn As Object, ByVal pesan As String)
    On Error Resume Next
    If Not conn Is Nothing Then
        If conn.State = 1 Then conn.RollbackTrans
    End If
    TutupKoneksi conn
    Application.ScreenUpdating = True
    Application.StatusBar = False
    On Error GoTo 0
    If mDipanggilTest Then
        Err.Raise vbObjectError + 514, , judul & " gagal, data bagian ini dibatalkan." & vbCrLf & pesan
    Else
        MsgBox judul & " gagal, data bagian ini dibatalkan." & vbCrLf & vbCrLf & pesan, vbCritical, "POST"
    End If
End Sub

'=====================================================================
'  1) DATA PROCESS PROD  ->  PO Daily Output, PO Details Reject, PO Header
'=====================================================================
Sub Post_PONOutput()
    Dim conn As Object, ws As Worksheet
    Dim B As Long, K As Long, nPO As Long, nRej As Long, nHdr As Long
    Dim tDateOpt, tRep, tPro, tShi, tPON, tLot, tMat, tSty, tGty, tRty, tRem
    Dim tRType As String, tRQty, tProduct As String, USR As String, DT As Date
    Dim alasan As String, sql As String

    On Error GoTo Gagal
    Set ws = ThisWorkbook.Sheets("Data Process Prod ")
    Set conn = BukaKoneksi()
    conn.BeginTrans

    conn.Execute "delete from dbo.tblBA204_PODailyOutput where DateOperation < DATEADD(year,-2,CAST(GETDATE() AS date))" 'Retention 2 years + current
    conn.Execute "delete from dbo.tblBA204_PODetailsReject where DateOperation < DATEADD(year,-2,CAST(GETDATE() AS date))"

    USR = Environ("Username")
    DT = Now
    tProduct = Trim$(CStr(ws.Range("C3").Value))

    'Sinkron: hapus dulu semua data bulan laporan ini, supaya baris yang tanggalnya
    'dihapus di Excel juga hilang dari database & dashboard
    Dim bln As Variant
    bln = BulanFile(ThisWorkbook.Sheets("Daily Output Summary"))
    If Not IsEmpty(bln) Then
        conn.Execute "delete from dbo.tblBA204_PODailyOutput where ProductType=" & SqlTeks(tProduct) & " and " & RentangBulan("DateReport", bln)
        conn.Execute "delete from dbo.tblBA204_PODetailsReject where ProductType=" & SqlTeks(tProduct) & " and " & RentangBulan("DateReport", bln)
    End If
    'baris PO yang masih berjalan (online, belum punya Date for Daily Report) selalu diisi ulang
    conn.Execute "delete from dbo.tblBA204_PODailyOutput where ProductType=" & SqlTeks(tProduct) & " and DateReport is null"
    conn.Execute "delete from dbo.tblBA204_PODetailsReject where ProductType=" & SqlTeks(tProduct) & " and DateReport is null"

    'posisi kolom header PO dicari dari judulnya
    Dim cNo As Long, cQC As Long, cStart As Long, cEnd As Long, cSup As Long, cStat As Long, cDesc As Long
    cNo = KolomHeader(ws, "No")
    cQC = KolomHeader(ws, "QC Released")
    cStart = KolomHeader(ws, "Start date")
    cEnd = KolomHeader(ws, "End Date")
    cSup = KolomHeader(ws, "Supplier")
    If cSup = 0 Then cSup = KolomHeader(ws, "Machine")
    cStat = KolomHeader(ws, "Production status")
    cDesc = KolomHeader(ws, "Material Desc")
    If cNo = 0 Then cNo = 20

    Dim sudah As Object
    Set sudah = CreateObject("Scripting.Dictionary")

    'Updating Table PO Daily Output
    B = 4
    tDateOpt = ws.Cells(B, 28).Value
    Do While Not Kosong(tDateOpt) Or Not Kosong(ws.Cells(B, 27).Value)
        tPro = Trim$(CStr(ws.Cells(B, 27).Value))
        If LCase$(tPro) = "total" Then Exit Do
        tShi = ws.Cells(B, 29).Value
        tRep = ws.Cells(B, 30).Value
        tPON = Trim$(CStr(ws.Cells(B, 31).Value))
        tLot = ws.Cells(B, 32).Value
        tMat = ws.Cells(B, 33).Value
        tSty = ws.Cells(B, 34).Value
        tGty = ws.Cells(B, 35).Value
        tRty = ws.Cells(B, 36).Value
        tRem = ws.Cells(B, 37).Value

        'Header PO (baris pertama tiap PO: kolom No terisi)
        If Not Kosong(ws.Cells(B, cNo).Value) And tPON <> "" Then
            conn.Execute "delete from dbo.tblBA204_POHeader where ProductType=" & SqlTeks(tProduct) & " and PON=" & SqlTeks(tPON)
            sql = "insert into dbo.tblBA204_POHeader (ProductType,PON,Batch,Material,MaterialDesc,Supplier,ProductionStatus,QCRelease,QCReleaseDate,StartDate,EndDate,InputBy,InputOn) values (" & _
                  SqlTeks(tProduct) & ", " & SqlTeks(tPON) & ", " & SqlTeks(tLot) & ", " & SqlTeks(tMat) & ", " & _
                  SqlTeks(NilaiKolom(ws, B, cDesc)) & ", " & SqlTeks(NilaiKolom(ws, B, cSup)) & ", " & SqlTeks(NilaiKolom(ws, B, cStat)) & ", " & _
                  SqlTeks(IIf(IsTanggal(NilaiKolom(ws, B, cQC)), "Released", NilaiKolom(ws, B, cQC))) & ", " & SqlTgl(NilaiKolom(ws, B, cQC)) & ", " & _
                  SqlTgl(NilaiKolom(ws, B, cStart)) & ", " & SqlTgl(NilaiKolom(ws, B, cEnd)) & ", " & SqlTeks(USR) & ", " & SqlWaktu(DT) & ")"
            conn.Execute sql
            nHdr = nHdr + 1
        End If

        alasan = ""
        If tPro = "" Then alasan = alasan & "; *Process kosong"
        If Not IsTanggal(tDateOpt) Then alasan = alasan & "; *Date Process kosong"
        'PO yang masih online (belum ada Date for Daily Report) tetap dikirim supaya
        'muncul di monitoring Status PO; output-nya baru dihitung di laporan setelah tanggal laporan diisi
        Dim online As Boolean
        online = Not IsTanggal(tRep)
        If tPON = "" Then alasan = alasan & "; *PO Number kosong"
        If Not online And Nz(tSty) <= 0 Then alasan = alasan & "; Start Output kosong"
        If Not AngkaValid(tRty) Then alasan = alasan & "; Scrap 'Mismatch'"

        If alasan = "" Then
            'Baris di bulan laporan sudah dibersihkan sekaligus di atas. Baris di luar bulan itu
            'dibersihkan per kunci SEKALI saja per POST, supaya beberapa baris dengan PO, proses
            'dan tanggal yang sama (beda shift / beda lot) tidak saling menimpa.
            Dim diBulan As Boolean, kunci As String, wh As String
            diBulan = False
            If online Then
                diBulan = True      'sudah dibersihkan di atas (DateReport is null)
            ElseIf Not IsEmpty(bln) Then
                diBulan = (DateSerial(Year(CDate(tRep)), Month(CDate(tRep)), 1) = bln)
            End If
            If Not diBulan Then
                wh = " where DateOperation=" & SqlTgl(tDateOpt) & " and DateReport=" & SqlTgl(tRep) & " and ProductType=" & SqlTeks(tProduct) & " and Process=" & SqlTeks(tPro) & " and PON=" & SqlTeks(tPON) & " and ISNULL(Shift,N'')=" & SqlTeks(tShi)
                kunci = wh
                If Not sudah.Exists(kunci) Then
                    sudah.Add kunci, True
                    conn.Execute "delete from dbo.tblBA204_PODailyOutput" & wh
                    conn.Execute "delete from dbo.tblBA204_PODetailsReject" & wh
                End If
            End If

            conn.Execute "insert into dbo.tblBA204_PODailyOutput (DateOperation,DateReport,Process,Shift,ProductType,PON,Batch,Material,Qty_Start,Qty_Output,Qty_Scrap,Remark,InputBy,InputOn) values (" & _
                SqlTgl(tDateOpt) & ", " & SqlTgl(tRep) & ", " & SqlTeks(tPro) & ", " & SqlTeks(tShi) & ", " & SqlTeks(tProduct) & ", " & _
                SqlTeks(tPON) & ", " & SqlTeks(tLot) & ", " & SqlTeks(tMat) & ", " & SqlAngka(tSty) & ", " & SqlAngka(tGty) & ", " & _
                SqlAngka(tRty) & ", " & SqlTeks(tRem) & ", " & SqlTeks(USR) & ", " & SqlWaktu(DT) & ")"
            nPO = nPO + 1

            K = 40
            tRType = Trim$(CStr(ws.Cells(3, K).Value))
            Do While tRType Like "(####)*"
                tRQty = ws.Cells(B, K).Value
                If Nz(tRQty) <> 0 Then
                    conn.Execute "insert into dbo.tblBA204_PODetailsReject (DateOperation,DateReport,Process,Shift,ProductType,PON,RejectType,Reject_qty,InputBy,InputOn) values (" & _
                        SqlTgl(tDateOpt) & ", " & SqlTgl(tRep) & ", " & SqlTeks(tPro) & ", " & SqlTeks(tShi) & ", " & SqlTeks(tProduct) & ", " & _
                        SqlTeks(tPON) & ", " & SqlTeks(tRType) & ", " & SqlAngka(tRQty) & ", " & SqlTeks(USR) & ", " & SqlWaktu(DT) & ")"
                    nRej = nRej + 1
                End If
                K = K + 1
                tRType = Trim$(CStr(ws.Cells(3, K).Value))
            Loop
        ElseIf tPro <> "" Or tPON <> "" Then
            CatatLewat ws.Name, "baris " & B, Mid$(alasan, 3)
        End If

        B = B + 1
        tDateOpt = ws.Cells(B, 28).Value
        If B Mod 50 = 0 Then Application.StatusBar = "POST Data Process Prod... baris " & B
    Loop

    'header PO yang sudah tidak punya data sama sekali ikut dihapus
    conn.Execute "delete h from dbo.tblBA204_POHeader h where h.ProductType=" & SqlTeks(tProduct) & _
                 " and not exists (select 1 from dbo.tblBA204_PODailyOutput o where o.PON = h.PON)" & _
                 " and not exists (select 1 from dbo.tblBA204_PODetailsReject r where r.PON = h.PON)"

    conn.CommitTrans
    TutupKoneksi conn
    Application.StatusBar = False
    SelesaiPost "Data Process Prod", nPO & " baris PO, " & nRej & " detail reject, " & nHdr & " header PO"
    Exit Sub
Gagal:
    GagalPost "POST Data Process Prod", conn, Err.Description
End Sub

'=====================================================================
'  2) DAILY SCRAP SUMMARY  ->  Details Reject 2
'=====================================================================
Sub Post_DetailsReject2()
    Dim conn As Object, ws As Worksheet
    Dim K As Long, B As Long, R As Long, n As Long
    Dim tDateOpt, tProduct As String, tProductSub As String, tReject As String, tQtyReject
    Dim USR As String, DT As Date

    On Error GoTo Gagal
    Set ws = ThisWorkbook.Sheets("Daily Scrap summary")
    Set conn = BukaKoneksi()
    conn.BeginTrans

    conn.Execute "delete from dbo.tblBA204_DetailsReject2 where DateOperation < DATEADD(year,-2,CAST(GETDATE() AS date))" 'Retention 2 years + current

    tProduct = Trim$(CStr(ws.Range("D4").Value))
    'Sinkron: hapus dulu data bulan laporan ini (kolom tanggal yang dikosongkan ikut hilang)
    Dim blnS As Variant
    blnS = BulanFile(ws)
    If Not IsEmpty(blnS) Then conn.Execute "delete from dbo.tblBA204_DetailsReject2 where ProductType=" & SqlTeks(tProduct) & " and " & RentangBulan("DateOperation", blnS)
    USR = Environ("Username")
    DT = Now

    For K = 5 To 35
        tDateOpt = ws.Cells(7, K).Value
        If IsTanggal(tDateOpt) Then
            'Execute delete t-SQL Script to clear previous record in the database
            conn.Execute "delete from dbo.tblBA204_DetailsReject2 where DateOperation=" & SqlTgl(tDateOpt) & " and ProductType=" & SqlTeks(tProduct)
            B = 8
            Do While Not Kosong(ws.Cells(B, 2).Value) And Not Kosong(ws.Cells(B + 1, 3).Value)
                tProductSub = Trim$(CStr(ws.Cells(B, 2).Value))
                For R = 1 To 25
                    tReject = Trim$(CStr(ws.Cells(B + R, 3).Value))
                    tQtyReject = ws.Cells(B + R, K).Value
                    If tReject <> "" And Nz(tQtyReject) <> 0 Then
                        conn.Execute "insert into dbo.tblBA204_DetailsReject2 (DateOperation,ProductType,ProductSubType,RejectType,Qty_Reject,InputBy,InputOn) values (" & _
                            SqlTgl(tDateOpt) & ", " & SqlTeks(tProduct) & ", " & SqlTeks(tProductSub) & ", " & SqlTeks(tReject) & ", " & _
                            SqlAngka(tQtyReject) & ", " & SqlTeks(USR) & ", " & SqlWaktu(DT) & ")"
                        n = n + 1
                    ElseIf tReject <> "" And Not AngkaValid(tQtyReject) Then
                        CatatLewat ws.Name, ws.Cells(B + R, K).Address(False, False), "nilai error"
                    End If
                Next R
                B = B + 26
            Loop
        End If
    Next K

    conn.CommitTrans
    TutupKoneksi conn
    SelesaiPost "Daily Scrap summary", n & " baris"
    Exit Sub
Gagal:
    GagalPost "POST Daily Scrap summary", conn, Err.Description
End Sub

'=====================================================================
'  3) DAILY OUTPUT SUMMARY  ->  Daily Output 2
'=====================================================================
Sub Post_DailyOutput2()
    Dim conn As Object, ws As Worksheet
    Dim K As Long, B As Long, n As Long
    Dim tDateOpt, tProduct As String, tProductSub As String
    Dim tQtyProcess, tQtyOutput, tQtyReject, tTargetYield, tTargetOutput, tRemark
    Dim USR As String, DT As Date

    On Error GoTo Gagal
    Set ws = ThisWorkbook.Sheets("Daily Output Summary")
    Set conn = BukaKoneksi()
    conn.BeginTrans

    conn.Execute "delete from dbo.tblBA204_DailyOutput2 where DateOperation < DATEADD(year,-2,CAST(GETDATE() AS date))" 'Retention 2 years + current

    tProduct = Trim$(CStr(ws.Range("D4").Value))
    'Sinkron: hapus dulu data bulan laporan ini (kolom tanggal yang dikosongkan ikut hilang)
    Dim blnS As Variant
    blnS = BulanFile(ws)
    If Not IsEmpty(blnS) Then conn.Execute "delete from dbo.tblBA204_DailyOutput2 where ProductType=" & SqlTeks(tProduct) & " and " & RentangBulan("DateOperation", blnS)
    USR = Environ("Username")
    DT = Now

    For K = 5 To 35
        tDateOpt = ws.Cells(7, K).Value
        If IsTanggal(tDateOpt) Then
            'Execute delete t-SQL Script to clear previous record in the database
            conn.Execute "delete from dbo.tblBA204_DailyOutput2 where DateOperation=" & SqlTgl(tDateOpt) & " and ProductType=" & SqlTeks(tProduct)
            B = 8
            Do While Not Kosong(ws.Cells(B, 2).Value) And Not Kosong(ws.Cells(B + 1, 3).Value)
                tProductSub = Trim$(CStr(ws.Cells(B, 2).Value))
                tQtyProcess = ws.Cells(B + 1, K).Value
                tQtyOutput = ws.Cells(B + 2, K).Value
                tQtyReject = ws.Cells(B + 3, K).Value
                tTargetYield = ws.Cells(B + 5, K).Value
                tTargetOutput = ws.Cells(B + 4, K).Value
                tRemark = ws.Cells(B + 12, K).Value
                If Not Kosong(tQtyOutput) Then
                    If AngkaValid(tQtyProcess) And AngkaValid(tQtyOutput) And AngkaValid(tQtyReject) _
                       And AngkaValid(tTargetYield) And AngkaValid(tTargetOutput) Then
                        conn.Execute "insert into dbo.tblBA204_DailyOutput2 (DateOperation,ProductType,ProductSubType,Qty_Process,Qty_Output,Qty_Reject,Target_Yield,Target_Output,Remark,InputBy,InputOn) values (" & _
                            SqlTgl(tDateOpt) & ", " & SqlTeks(tProduct) & ", " & SqlTeks(tProductSub) & ", " & SqlAngka(tQtyProcess) & ", " & _
                            SqlAngka(tQtyOutput) & ", " & SqlAngka(tQtyReject) & ", " & SqlAngka(tTargetYield) & ", " & SqlAngka(tTargetOutput) & ", " & _
                            SqlTeks(tRemark) & ", " & SqlTeks(USR) & ", " & SqlWaktu(DT) & ")"
                        n = n + 1
                    Else
                        CatatLewat ws.Name, ws.Cells(B + 1, K).Address(False, False), "ada nilai error"
                    End If
                End If
                B = B + 13
            Loop
        End If
    Next K

    conn.CommitTrans
    TutupKoneksi conn
    SelesaiPost "Daily Output Summary", n & " baris"
    Exit Sub
Gagal:
    GagalPost "POST Daily Output Summary", conn, Err.Description
End Sub

'=====================================================================
'  4) DAILY PRODUCTIVITY SUMMARY  ->  Productivity 2
'=====================================================================
Sub Post_Productivity2()
    Dim conn As Object, ws As Worksheet
    Dim K As Long, n As Long
    Dim tDateOpt, tProduct As String, USR As String, DT As Date
    Dim tMaxMHP, tMaxOT, tActOutput, tTotalHC, tAbsentHC, tNormalManHours
    Dim tLostManHours, tActOT, tSupportManHours, tTotalManhours, tActManhours, tRemark

    On Error GoTo Gagal
    Set ws = ThisWorkbook.Sheets("Daily Productivity Summary")
    Set conn = BukaKoneksi()
    conn.BeginTrans

    conn.Execute "delete from dbo.tblBA204_Productivity2 where DateOperation < DATEADD(year,-2,CAST(GETDATE() AS date))" 'Retention 2 years + current

    tProduct = Trim$(CStr(ws.Range("D4").Value))
    'Sinkron: hapus dulu data bulan laporan ini (kolom tanggal yang dikosongkan ikut hilang)
    Dim blnS As Variant
    blnS = BulanFile(ws)
    If Not IsEmpty(blnS) Then conn.Execute "delete from dbo.tblBA204_Productivity2 where ProductType=" & SqlTeks(tProduct) & " and " & RentangBulan("DateOperation", blnS)
    USR = Environ("Username")
    DT = Now

    For K = 4 To 34
        tDateOpt = ws.Cells(7, K).Value
        If IsTanggal(tDateOpt) Then
            'Execute delete t-SQL Script to clear previous record in the database
            conn.Execute "delete from dbo.tblBA204_Productivity2 where DateOperation=" & SqlTgl(tDateOpt) & " and ProductType=" & SqlTeks(tProduct)
            tMaxMHP = Nz(ws.Cells(8, K).Value)
            tMaxOT = Nz(ws.Cells(9, K).Value)
            tActOutput = Nz(ws.Cells(10, K).Value)
            tTotalHC = Nz(ws.Cells(11, K).Value)
            tAbsentHC = Nz(ws.Cells(12, K).Value)
            tNormalManHours = Nz(ws.Cells(13, K).Value)
            tLostManHours = Nz(ws.Cells(14, K).Value)
            tActOT = Nz(ws.Cells(15, K).Value)
            tSupportManHours = Nz(ws.Cells(16, K).Value)
            tTotalManhours = Nz(ws.Cells(17, K).Value)
            tActManhours = Nz(ws.Cells(19, K).Value)
            tRemark = ws.Cells(20, K).Value

            If tMaxMHP > 0 Then
                'Execute insert t-SQL Script to save record into database
                conn.Execute "insert into dbo.tblBA204_Productivity2 (DateOperation,ProductType,MaxMHP,MaxOT,ActOutput,TotalHC,AbsentHC,NormalManHours,LostManHours,ActOT,SupportManHours,TotalManhours,ActManhours,Remark,InputBy,InputOn) values (" & _
                    SqlTgl(tDateOpt) & ", " & SqlTeks(tProduct) & ", " & SqlAngka(tMaxMHP) & ", " & SqlAngka(tMaxOT) & ", " & SqlAngka(tActOutput) & ", " & _
                    SqlAngka(tTotalHC) & ", " & SqlAngka(tAbsentHC) & ", " & SqlAngka(tNormalManHours) & ", " & SqlAngka(tLostManHours) & ", " & _
                    SqlAngka(tActOT) & ", " & SqlAngka(tSupportManHours) & ", " & SqlAngka(tTotalManhours) & ", " & SqlAngka(tActManhours) & ", " & _
                    SqlTeks(tRemark) & ", " & SqlTeks(USR) & ", " & SqlWaktu(DT) & ")"
                n = n + 1
            End If
        End If
    Next K

    conn.CommitTrans
    TutupKoneksi conn
    SelesaiPost "Daily Productivity Summary", n & " baris"
    Exit Sub
Gagal:
    GagalPost "POST Daily Productivity Summary", conn, Err.Description
End Sub

'=====================================================================
'  TOMBOL POST : kirim semua sheet
'=====================================================================
Sub Test()
    Dim mulai As Double, langkah As String
    mulai = Timer
    mDipanggilTest = True
    mRingkasan = "": mDilewati = "": mJumlahLewat = 0

    On Error GoTo Gagal
    Application.ScreenUpdating = False
    Application.Cursor = xlWait
    Application.Calculate

    langkah = "Data Process Prod":          Application.StatusBar = "POST " & langkah & "...": Call Post_PONOutput
    langkah = "Daily Scrap summary":        Application.StatusBar = "POST " & langkah & "...": Call Post_DetailsReject2
    langkah = "Daily Output Summary":       Application.StatusBar = "POST " & langkah & "...": Call Post_DailyOutput2
    langkah = "Daily Productivity Summary": Application.StatusBar = "POST " & langkah & "...": Call Post_Productivity2

    Application.ScreenUpdating = True
    Application.Cursor = xlDefault
    Application.StatusBar = False
    mDipanggilTest = False

    MsgBox "The Data was posted successfully (" & Format$(Timer - mulai, "0.0") & " detik)" & vbCrLf & _
           mRingkasan & vbCrLf & vbCrLf & _
           "Web dashboard (http://localhost:3000) akan ter-update otomatis dalam beberapa detik." & _
           IIf(mJumlahLewat > 0, vbCrLf & vbCrLf & mJumlahLewat & " baris dilewati karena belum lengkap:" & mDilewati, ""), _
           vbInformation, "PBL Monitoring Produksi"
    mJumlahLewat = 0: mDilewati = ""
    Exit Sub

Gagal:
    Application.ScreenUpdating = True
    Application.Cursor = xlDefault
    Application.StatusBar = False
    mDipanggilTest = False
    MsgBox "POST berhenti di sheet '" & langkah & "'." & vbCrLf & vbCrLf & Err.Description & vbCrLf & vbCrLf & _
           "Bagian sebelumnya: " & IIf(mRingkasan = "", "-", mRingkasan), vbCritical, "PBL Monitoring Produksi"
End Sub

'Cek koneksi ke database lokal
Sub TesKoneksi()
    Dim conn As Object, rs As Object
    On Error GoTo Gagal
    Set conn = BukaKoneksi()
    Set rs = conn.Execute("SELECT @@SERVERNAME, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(30)), (SELECT COUNT(*) FROM dbo.tblBA204_PODailyOutput)")
    MsgBox "Koneksi BERHASIL" & vbCrLf & vbCrLf & "Server : " & rs.Fields(0).Value & vbCrLf & _
           "Versi  : " & rs.Fields(1).Value & vbCrLf & "Database: " & DB_NAME & vbCrLf & _
           "Baris PO tersimpan: " & rs.Fields(2).Value, vbInformation, "Tes Koneksi"
    rs.Close
    TutupKoneksi conn
    Exit Sub
Gagal:
    TutupKoneksi conn
    MsgBox Err.Description, vbCritical, "Tes Koneksi GAGAL"
End Sub
